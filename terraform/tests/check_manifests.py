"""Validate rendered manifests, not just the input values. Requires PyYAML."""
import sys
from pathlib import Path
import yaml

root = Path(sys.argv[1])
values = yaml.safe_load((root / 'gitlab-values.yml').read_text())
ip_access = values['global']['hosts']['gitlab']['name'] == '192.0.2.10'
routes = [x for x in yaml.safe_load_all((root / 'routes.yml').read_text()) if x]
gitlab = [x for x in yaml.safe_load_all((root / 'gitlab-manifests.yml').read_text()) if x]
ingress = [x for x in yaml.safe_load_all((root / 'traefik-manifests.yml').read_text()) if x]

def resource(items, kind, name):
    return next(x for x in items if x['kind'] == kind and x['metadata']['name'] == name)

for name, minimum in [('webservice-default', 6), ('sidekiq-all-in-1-v2', 6), ('gitlab-shell', 3), ('kas', 3), ('registry', 3)]:
    hpa = resource(gitlab, 'HorizontalPodAutoscaler', f'gitlab-{name}')
    assert hpa['apiVersion'] == 'autoscaling/v2'
    assert hpa['spec']['minReplicas'] >= minimum
    assert hpa['spec']['maxReplicas'] >= minimum
    labels = resource(gitlab, 'Deployment', f'gitlab-{name}')['spec']['template']['metadata']['labels']
    assert any(d['kind'] == 'PodDisruptionBudget' and all(labels.get(k) == v for k, v in d['spec']['selector']['matchLabels'].items()) for d in gitlab)

for name, pool in [('webservice-default', 'web'), ('sidekiq-all-in-1-v2', 'sidekiq'), ('gitlab-shell', 'support'), ('kas', 'support')]:
    pod = resource(gitlab, 'Deployment', f'gitlab-{name}')['spec']['template']['spec']
    assert pod['nodeSelector']['gitlab-pool'] == pool
    assert pod.get('topologySpreadConstraints') or pod.get('affinity', {}).get('podAntiAffinity')

# Regression: all four 7-GiB Rails containers OOMKilled in the retained GitLab Performance Tool run.
# Check rendered chart behavior: unknown Helm values can otherwise be ignored.
web = resource(gitlab, 'Deployment', 'gitlab-webservice-default')
rails = next(c for c in web['spec']['template']['spec']['containers'] if c['name'] == 'webservice')
env = {v['name']: v.get('value') for v in rails['env']}
assert env['DISABLE_PUMA_WORKER_KILLER'] == 'false'
assert env['PUMA_WORKER_MAX_MEMORY'] == '1500'
assert rails['resources']['requests']['memory'] == rails['resources']['limits']['memory'] == '12Gi'
assert 'cpu' not in rails['resources']['limits'], 'Do not throttle Rails during bursts'
assert web['spec']['strategy']['rollingUpdate'] == {'maxSurge': 0, 'maxUnavailable': 1}

# Verify TLS reaches the actual containers and migrations, not just a values key.
for name in ['webservice-default', 'sidekiq-all-in-1-v2', 'toolbox']:
    pod = resource(gitlab, 'Deployment', f'gitlab-{name}')['spec']['template']['spec']
    container = pod['containers'][0]
    env = {v['name']: v.get('value') for v in container['env']}
    assert env['PGSSLMODE'] == 'verify-full'
    assert env['PGSSLROOTCERT'] == '/etc/ssl/certs/ca-certificates.crt'
    assert any(v['name'] == 'etc-ssl-certs' for v in container['volumeMounts'])

config_text = '\n'.join(str(x.get('data', {})) for x in gitlab if x['kind'] == 'ConfigMap')
assert 'rediss://primary.redis.example.test:6379' in config_text
assert 'tls://10.60.8.20:3305' in config_text
assert 'main.postgresql.example.test' in config_text
assert not any(x['kind'] == 'StatefulSet' for x in gitlab), 'No bundled stateful GitLab services permitted'
for r in [x for x in gitlab if x['kind'] == 'Ingress']:
    assert r['apiVersion'] == 'networking.k8s.io/v1'
    assert r['spec']['tls'][0]['secretName'] == 'gitlab-public-tls'
    assert r['spec']['ingressClassName'] == 'traefik'
ssh = resource(gitlab, 'IngressRouteTCP', 'gitlab-gitlab-shell')
assert ssh['apiVersion'] == 'traefik.io/v1alpha1'
assert ssh['spec']['entryPoints'] == ['gitlab-shell']

service = resource(ingress, 'Service', 'traefik')['spec']
assert service['loadBalancerIP'] == '192.0.2.10'
assert {p['port'] for p in service['ports']} == ({22, 80, 443, 5050, 8150} if ip_access else {22, 80, 443})
assert resource(ingress, 'Deployment', 'traefik')['spec']['replicas'] == 3
resource(ingress, 'PodDisruptionBudget', 'traefik')
assert resource(gitlab, 'Deployment', 'gitlab-prometheus-server')['spec']['replicas'] == 2
backup = next(x for x in gitlab if x['kind'] == 'CronJob')
assert backup['spec']['concurrencyPolicy'] == 'Forbid'
volumes = backup['spec']['jobTemplate']['spec']['template']['spec']['volumes']
assert any(v.get('ephemeral', {}).get('volumeClaimTemplate', {}).get('spec', {}).get('storageClassName') == 'oci-bv' for v in volumes)
secrets = [x for x in yaml.safe_load_all((root / 'secrets.yml').read_text()) if x]
objects = resource(secrets, 'Secret', 'gitlab-object-storage')['stringData']
connection = yaml.safe_load(objects['connection'])
assert connection['path_style'] is True and connection['enable_signature_v4_streaming'] is False
registry = yaml.safe_load(objects['registry'])
assert registry['s3_v2']['checksum_disabled'] is True
assert registry['s3_v2']['pathstyle'] is True
assert registry['redirect']['disable'] is True
assert 'host_bucket = test.compat.objectstorage.' in objects['s3cfg']
assert resource(routes, 'TLSStore', 'default')['spec']['defaultCertificate']['secretName'] == 'gitlab-public-tls'
assert 'gitlab-public.crt' in resource(secrets, 'Secret', 'gitlab-private-ca')['data']
if ip_access:
    assert not any(x['kind'] == 'Ingress' for x in gitlab), 'IP literals must not become Ingress hostnames'
    expected = [('gitlab-public-ip', 'websecure', 'gitlab-webservice-default', 8181),
                ('gitlab-registry-ip', 'registry', 'gitlab-registry', 5000),
                ('gitlab-kas-ip', 'kas', 'gitlab-kas', 8150)]
    for name, entrypoint, backend, port in expected:
        route = resource(routes, 'IngressRoute', name)['spec']
        assert route['entryPoints'] == [entrypoint]
        assert route['tls']['secretName'] == 'gitlab-public-tls'
        assert any(r['match'] == 'PathPrefix(`/`)' and r['services'] == [{'name': backend, 'port': port}] for r in route['routes'])
    assert 'wss://192.0.2.10:8150' in config_text
    assert values['global']['registry']['port'] == 5050
    assert values['global']['hosts']['ssh'] == '192.0.2.10'
else:
    assert len(routes) == 1
    hosts = {r['host'] for x in gitlab if x['kind'] == 'Ingress' for r in x['spec']['rules']}
    assert hosts == {'gitlab.example.test', 'registry.example.test', 'kas.example.test'}
    assert values['global']['registry']['port'] == 443
assert 'default_replication_factor: 3' in (root / 'praefect.rb').read_text()
print(f'PASS: checked HA, scheduling, TLS, private backends, ingress and backups in {len(gitlab) + len(ingress)} rendered objects')
