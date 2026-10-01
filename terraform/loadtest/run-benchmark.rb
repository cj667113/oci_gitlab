#!/usr/bin/env ruby
# Entry point for Ansible benchmarks on OKE using the official GitLab Performance Tool image.
require 'json'
require 'fileutils'
require 'open3'
require 'net/http'
require 'time'
$stdout.sync = true
root = ENV.fetch('GPT_HOME', '/performance')
results = File.expand_path(ENV.fetch('GPT_DOCKER_RESULTS_DIR', '/results'))
FileUtils.mkdir_p(results)
ENV['GPT_DOCKER_RESULTS_DIR'] = results
ENV['GPT_TTFB_P95'] = 'true'
ENV['GPT_GENERATOR_POOL_SIZE'] ||= '4'
# Retain public trust for GPT's upstream downloads as well as the dev CA.
if ENV['SSL_CERT_FILE'] && File.file?('/etc/ssl/certs/ca-certificates.crt')
  bundle = '/tmp/gpt-ca-bundle.pem'
  File.write(bundle, File.read('/etc/ssl/certs/ca-certificates.crt') + "\n" + File.read(ENV['SSL_CERT_FILE']))
  ENV['SSL_CERT_FILE'] = bundle
end
config = JSON.parse(File.read("#{root}/k6/config/environments/2k.json"))
config['environment'].merge!('name' => ENV.fetch('GPT_ENVIRONMENT', 'oke-2k'), 'url' => ENV.fetch('TARGET_URL'), 'user' => ENV.fetch('GPT_USER', 'root'), 'storage_nodes' => ENV.fetch('GPT_STORAGE_NODES', 'default').split(','))
config['gpt_data']['root_group'] = ENV.fetch('GPT_ROOT_GROUP', 'gpt-benchmark')
config_path = "#{results}/environment.json"
File.write(config_path, JSON.pretty_generate(config))
full_suite = ENV.fetch('GPT_FULL_SUITE', 'false') == 'true'
File.write("#{results}/run-manifest.json", JSON.pretty_generate({
  'image' => ENV['GPT_IMAGE'], 'profile' => ENV.fetch('GPT_OPTIONS', '60s_40rps.json'),
  'tests' => ENV.fetch('GPT_TESTS', 'tests'), 'data_profile' => 'upstream 2k (1000 subgroups, 10 projects each, gitlabhq)',
  'generator_pool_size' => ENV['GPT_GENERATOR_POOL_SIZE'],
  'data_generator_patch' => 'resume incomplete subgroups in place instead of deleting them',
  'full_suite' => full_suite,
  'unsafe' => full_suite, 'scenarios' => full_suite,
  'quarantined' => full_suite, 'experimental' => full_suite
}))
def run_logged(argv, path)
  File.open(path, 'a') do |log|
    Open3.popen2e(*argv) do |stdin, out, waiter|
      stdin.close
      out.each_line do |line|
        line = line.gsub(ENV.fetch('ACCESS_TOKEN'), '[REDACTED]')
        print line; log.write(line); log.flush
      end
      return waiter.value.exitstatus || 1
    end
  end
end
def api_request(method, path, payload = nil)
  uri = URI(ENV.fetch('TARGET_URL') + '/api/v4/' + path)
  request = method.new(uri)
  request['PRIVATE-TOKEN'] = ENV.fetch('ACCESS_TOKEN')
  request['Content-Type'] = 'application/json'
  request.body = JSON.generate(payload) if payload
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(request) }
  raise "GitLab API returned #{response.code} for #{path}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end
def settings_request(method, payload = nil)
  api_request(method, 'application/settings', payload)
end
status = 1
original = nil
phase = 'preparation'
stop_sampling = false
sampler = Thread.new do
  loop do
    sample = { 'time' => Time.now.utc.iso8601, 'phase' => phase }
    { 'cpu' => '/sys/fs/cgroup/cpu.stat', 'cpu_limit' => '/sys/fs/cgroup/cpu.max',
      'memory_bytes' => '/sys/fs/cgroup/memory.current', 'memory_limit_bytes' => '/sys/fs/cgroup/memory.max' }.each do |key, path|
      sample[key] = File.read(path).strip if File.readable?(path)
    end
    File.open("#{results}/generator-resources.jsonl", 'a') { |file| file.puts(JSON.generate(sample)) }
    break if stop_sampling
    sleep 10
  end
end
begin
  initial_settings = settings_request(Net::HTTP::Get)
  original = initial_settings.select { |key, _| key.match?(/limit|\Aimport_sources\z|\Amax_import_size\z|\Arepository_storages|\Adelayed_.*deletion\z|\Adeletion_adjourned_period\z/i) }
  coverage = nil
  if full_suite
    coverage = Dir.glob("#{root}/k6/tests/**/*.js").sort.map do |path|
      source = File.read(path)
      reason = if source.include?('@flags: vulnerabilities')
                 'Requires an Ultimate license and generated vulnerability fixtures; neither is configured for this run.'
               elsif source.include?('"elasticsearch_indexing": true') && !initial_settings['elasticsearch_indexing']
                 'Advanced search and an indexed Elasticsearch/OpenSearch service are not configured (paid license required).'
               elsif source.include?('"instance_level_ai_beta_features_enabled": true') && !initial_settings['instance_level_ai_beta_features_enabled']
                 'GitLab Duo/AI entitlement, activation, and feature prerequisites are not configured.'
               end
      { 'name' => File.basename(path, '.js'), 'path' => path.delete_prefix("#{root}/"),
        'category' => File.basename(File.dirname(path)),
        'status' => reason ? 'blocked' : 'selected', 'reason' => reason }
    end
    File.write("#{results}/suite-coverage.json", JSON.pretty_generate(coverage))
    puts "Full suite inventory: #{coverage.size}; selected: #{coverage.count { |t| t['status'] == 'selected' }}; blocked by prerequisites: #{coverage.count { |t| t['status'] == 'blocked' }}"
  end
  File.write("#{results}/benchmark-settings-before.json", JSON.pretty_generate(original))
  # Existing-data checks exceed default API limits. GPT interprets a 429 here
  # as a missing group/project, then attempts a duplicate creation.
  preparation_limits = %w[group_api_limit groups_api_limit group_projects_api_limit project_api_limit projects_api_limit group_create_limit project_create_limit]
  overrides = preparation_limits.select { |key| original.key?(key) }.to_h { |key| [key, 0] }
  # Enable imports before horizontal validation so every web process has time
  # to refresh its application-settings cache before Workhorse authorizes it.
  overrides['import_sources'] = (original.fetch('import_sources', []) + ['gitlab_project']).uniq
  overrides['max_import_size'] = 10240
  settings_request(Net::HTTP::Put, overrides) unless overrides.empty?
  File.write("#{results}/preparation-settings-overrides.json", JSON.pretty_generate(overrides))
  # GPT 1.5.0 otherwise deletes a partial subgroup before retrying. GitLab's
  # delayed deletion prevents immediate reuse. create_projects already skips
  # existing projects, so let it fill partial groups as well as empty groups.
  generator_library = "#{root}/lib/gpt_test_data.rb"
  generator_source = File.read(generator_library)
  compatibility_changes = {
    'if existing_projects_count.zero?' => 'if existing_projects_count < projects_count',
    'parent_group = recreate_group(group: parent_group, parent_group: root_group, log_only_to_file: false) if existing_subgroups_count > subgroups_count' =>
      "raise IncorrectProjectDataError, 'Extra subgroups in the reserved GPT data group; inspect before retrying' if existing_subgroups_count > subgroups_count",
    'sub_groups_without_projects << recreate_group(group: sub_group, parent_group:)' =>
      "raise IncorrectProjectDataError, 'Extra projects in a GPT subgroup; inspect before retrying'"
  }
  compatibility_changes.each do |before, after|
    if generator_source.include?(before)
      raise 'Unexpected generator source; review the pinned image' unless generator_source.scan(before).length == 1
      generator_source = generator_source.sub(before, after)
    elsif !generator_source.include?(after)
      raise 'GPT generator compatibility check failed'
    end
  end
  File.write(generator_library, generator_source)
  Dir.chdir(root)
  3.times do |attempt|
    puts "Data generation attempt #{attempt + 1}/3 (pool size #{ENV['GPT_GENERATOR_POOL_SIZE']})"
    File.open("#{results}/generator.log", 'a') { |log| log.puts("Data generation attempt #{attempt + 1}/3") }
    status = run_logged(['ruby', 'bin/generate-gpt-data', '--environment', config_path, '--unattended'], "#{results}/generator.log")
    break if status.zero?
    sleep 5 if attempt < 2
  end
  if status.zero?
    if full_suite
      # Upstream scenarios search for groups by name before deleting/recreating
      # their fixtures. Refuse any collision outside our reserved root group.
      root_path = config['gpt_data']['root_group']
      prefixes = Dir.glob("#{root}/k6/tests/scenarios/*.js").flat_map { |p| File.read(p).scan(/searchAndCreateGroup\(["']([^"']+)/).flatten }.uniq
      prefixes.each do |prefix|
        page = 1
        loop do
          groups = api_request(Net::HTTP::Get, "groups?search=#{URI.encode_www_form_component(prefix)}&per_page=100&page=#{page}")
          raise "Scenario group collision outside #{root_path}: #{prefix}" if groups.any? { |g| !g['full_path'].start_with?(root_path + '/') }
          break if groups.size < 100
          page += 1
        end
      end
    end
    phase = 'benchmark'
    selected_tests = full_suite ? coverage.select { |t| t['status'] == 'selected' }.map { |t| t['path'] } : ENV.fetch('GPT_TESTS', 'tests').split(',')
    flags = full_suite ? %w[--unsafe --scenarios --quarantined --experimental] : []
    status = run_logged(['ruby', 'bin/run-k6', '--environment', config_path, '--options', ENV.fetch('GPT_OPTIONS', '60s_40rps.json'), '--tests', *selected_tests, *flags, '--rate-limits', '--unattended'], "#{results}/benchmark.log")
    if coverage
      native = Dir.glob("#{results}/**/*_results.json").reject { |p| p.include?('/test_results/') || p.include?('/failed_test_results/') }.flat_map { |p| JSON.parse(File.read(p)).fetch('test_results', []) }
      coverage.each do |test|
        next if test['status'] == 'blocked'
        row = native.find { |r| r['name'] == test['name'] || r['name'] == test['name'] + '.js' }
        test['status'] = row ? (row['result'] ? 'passed' : 'failed') : 'not_reported'
      end
      File.write("#{results}/suite-coverage.json", JSON.pretty_generate(coverage))
      status = 1 if coverage.any? { |t| %w[failed not_reported].include?(t['status']) }
    end
  end
rescue StandardError => e
  warn e.full_message
  File.write("#{results}/error.log", e.full_message)
  status = 1
ensure
  phase = 'restoring'
  if original
    begin
      current = settings_request(Net::HTTP::Get)
      changed = original.select { |key, value| current[key] != value }
      settings_request(Net::HTTP::Put, changed) unless changed.empty?
      File.write("#{results}/settings-restored", Time.now.utc.to_s)
    rescue StandardError => e
      warn "Settings restoration failed: #{e.message}; use benchmark-settings-before.json to recover."
      status = 1
    end
  end
  stop_sampling = true
  begin
    sampler.wakeup if sampler.alive?
  rescue ThreadError
    # The final sample may have completed between alive? and wakeup.
  end
  sampler.join
  File.write("#{results}/exit-code", status.to_s)
  if ENV['GPT_WAIT_FOR_COLLECTION'] == 'true'
    # Keep the volume available for Ansible to fetch even when GPT failed.
    720.times do
      break if File.exist?("#{results}/collected")
      sleep 5
    end
  end
end
exit status
