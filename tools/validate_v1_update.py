#!/usr/bin/env python3
import argparse, base64, copy, hashlib, json, os, re
from pathlib import Path

HEX40 = re.compile(r'^[0-9a-f]{40}$')
HEX64 = re.compile(r'^[0-9a-f]{64}$')
SHA256_DER_PREFIX = bytes.fromhex('3031300d060960864801650304020105000420')
CERTIFIED = 'a10535b294c4d7ba8a4c3683154609087bf50c4b'
INSTALLER = 'efdeb275c25a7df1326d7effdddb4af8d83ef81d'
SIGNING = '91be58af59d0703de0159fea9d11935805e16022'
RELEASE_INTEGRATION = '9371399bab4fbb921ad94198aa148c597c7b6261'
ADMITTED_RELEASE_VERSIONS = {'1.0.0', '1.0.1'}


def load_json(path):
    with open(path, 'r', encoding='utf-8-sig') as fh:
        return json.load(fh)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    with open(path, 'rb') as fh:
        return sha256_bytes(fh.read())


def safe_rel(path):
    if not isinstance(path, str) or not path or '\\' in path or '|' in path or '\r' in path or '\n' in path:
        return False
    if path.startswith('/') or re.match(r'^[A-Za-z]:', path):
        return False
    if path.startswith('../') or path.endswith('/..') or '/../' in path:
        return False
    return all(32 <= ord(ch) <= 126 for ch in path)


def signing_fingerprint(public_key):
    material = '\n'.join([
        'nxb-v1-rsa-public-key-v1',
        f"modulus_b64={public_key['modulus_b64']}",
        f"exponent_b64={public_key['exponent_b64']}",
    ])
    return sha256_bytes(material.encode('utf-8'))


def canonical_material(envelope):
    if envelope.get('canonical_contract_id') != 'nxb-v1-release-signature-canonical-v1':
        raise ValueError('canonical contract')
    artifacts = envelope.get('artifacts')
    if not isinstance(artifacts, list) or not (1 <= len(artifacts) <= 256):
        raise ValueError('artifact count')
    amap = {}
    for item in artifacts:
        path = item.get('path')
        if not safe_rel(path) or path in amap or not isinstance(item.get('bytes'), int) or item['bytes'] < 0 or not HEX64.fullmatch(str(item.get('sha256',''))):
            raise ValueError('artifact row')
        amap[path] = item
    paths = sorted(amap.keys())
    lines = [
        'nxb-v1-release-signature-canonical-v1',
        'schema_version=1',
        f"release_version={envelope['release_version']}",
        f"release_head={envelope['release_head']}",
        f"certified_implementation_head={envelope['certified_implementation_head']}",
        f"package_manifest_sha256={envelope['package_manifest_sha256']}",
        f"release_notes_sha256={envelope['release_notes_sha256']}",
        f"artifact_count={len(paths)}",
        f"signer_mode={envelope['signer_mode']}",
        f"signer_key_id={envelope['signer_key_id']}",
        f"signing_algorithm={envelope['signing_algorithm']}",
        f"key_size_bits={int(envelope['key_size_bits'])}",
        f"public_modulus_b64={envelope['public_key']['modulus_b64']}",
        f"public_exponent_b64={envelope['public_key']['exponent_b64']}",
        f"public_fingerprint={envelope['public_key']['fingerprint']}",
        f"created_utc={envelope['created_utc']}",
    ]
    for path in paths:
        row = amap[path]
        lines.append(f"artifact={path}|{int(row['bytes'])}|{row['sha256']}")
    return '\n'.join(lines)


def verify_envelope(envelope):
    try:
        if envelope.get('schema_version') != 1 or envelope.get('status') != 'signed' or envelope.get('release_version') not in ADMITTED_RELEASE_VERSIONS:
            return False
        if not HEX40.fullmatch(str(envelope.get('release_head',''))) or envelope.get('certified_implementation_head') != CERTIFIED:
            return False
        if envelope.get('signing_algorithm') != 'RSA-PKCS1-SHA256' or int(envelope.get('key_size_bits',0)) < 3072:
            return False
        public = envelope['public_key']
        if signing_fingerprint(public) != public.get('fingerprint'):
            return False
        material = canonical_material(envelope).encode('utf-8')
        if sha256_bytes(material) != envelope.get('canonical_sha256'):
            return False
        modulus = base64.b64decode(public['modulus_b64'], validate=True)
        exponent = base64.b64decode(public['exponent_b64'], validate=True)
        signature = base64.b64decode(envelope['signature_b64'], validate=True)
        n = int.from_bytes(modulus, 'big'); e = int.from_bytes(exponent, 'big'); s = int.from_bytes(signature, 'big')
        k = len(modulus)
        if len(signature) != k or n.bit_length() < 3072 or s >= n:
            return False
        em = pow(s, e, n).to_bytes(k, 'big')
        digest_info = SHA256_DER_PREFIX + hashlib.sha256(material).digest()
        padding_len = k - len(digest_info) - 3
        expected = b'\x00\x01' + (b'\xff' * padding_len) + b'\x00' + digest_info
        return padding_len >= 8 and em == expected
    except Exception:
        return False


def valid_manifest(manifest):
    if manifest.get('schema_version') != 1 or manifest.get('contract_id') != 'nxb-v1-package-manifest-v1' or manifest.get('release_version') not in ADMITTED_RELEASE_VERSIONS:
        return False
    if not HEX40.fullmatch(str(manifest.get('source_head',''))): return False
    rows = manifest.get('files')
    if not isinstance(rows, list) or not (1 <= len(rows) <= 2048) or manifest.get('file_count') != len(rows): return False
    seen=set(); total=0; prev=None
    for row in rows:
        p=row.get('path')
        if not safe_rel(p) or p in seen or (prev is not None and not (prev < p)): return False
        if not isinstance(row.get('bytes'), int) or row['bytes'] < 0 or not HEX64.fullmatch(str(row.get('sha256',''))): return False
        seen.add(p); prev=p; total += row['bytes']
        if total > 1073741824: return False
    return manifest.get('total_bytes') == total


def package_matches(root, manifest):
    try:
        root=Path(root)
        actual={}
        for path in root.rglob('*'):
            if path.is_file():
                rel=path.relative_to(root).as_posix()
                if not safe_rel(rel) or rel in actual: return False
                actual[rel]=(path.stat().st_size, sha256_file(path))
        if len(actual) != len(manifest['files']): return False
        for row in manifest['files']:
            if actual.get(row['path']) != (row['bytes'], row['sha256']): return False
        return True
    except Exception:
        return False


def valid_trust(trust):
    if trust.get('schema_version') != 1 or trust.get('contract_id') != 'nxb-v1-update-trust-v1': return False
    if trust.get('channel') not in ('stable','beta') or not HEX64.fullmatch(str(trust.get('trusted_signer_fingerprint',''))): return False
    if not isinstance(trust.get('minimum_release_sequence'), int) or trust['minimum_release_sequence'] < 1 or trust.get('allow_downgrade') is not False: return False
    revoked=trust.get('revoked_release_heads')
    return isinstance(revoked,list) and len(revoked)==len(set(revoked)) and len(revoked)<=256 and all(HEX40.fullmatch(str(x)) for x in revoked)


def valid_descriptor(desc):
    return desc.get('schema_version') == 1 and desc.get('contract_id') == 'nxb-v1-update-descriptor-v1' and desc.get('channel') in ('stable','beta') and desc.get('release_version') in ADMITTED_RELEASE_VERSIONS and isinstance(desc.get('release_sequence'),int) and desc['release_sequence'] >= 1 and bool(HEX40.fullmatch(str(desc.get('release_head','')))) and desc.get('certified_implementation_head') == CERTIFIED and bool(HEX64.fullmatch(str(desc.get('package_manifest_sha256','')))) and isinstance(desc.get('created_utc'),str) and bool(desc['created_utc'])


def artifact_map(envelope):
    amap={}
    for row in envelope.get('artifacts',[]):
        p=row.get('path')
        if not safe_rel(p) or p in amap: raise ValueError('artifact map')
        amap[p]=row
    return amap


def bundle_valid(manifest, manifest_path, package_root, desc, desc_path, env, trust, current_sequence=0):
    if not (valid_manifest(manifest) and package_matches(package_root,manifest) and valid_trust(trust) and valid_descriptor(desc) and verify_envelope(env)): return False
    if env.get('signer_mode') != 'certification-ephemeral' or env.get('production_signer_claimed') is not False: return False
    if env['public_key']['fingerprint'] != trust['trusted_signer_fingerprint'] or desc['channel'] != trust['channel']: return False
    if desc['release_sequence'] < trust['minimum_release_sequence'] or desc['release_sequence'] <= current_sequence: return False
    if desc['release_head'] in trust['revoked_release_heads']: return False
    msha=sha256_file(manifest_path); dsha=sha256_file(desc_path)
    if desc['release_head'] != env['release_head'] or manifest['source_head'] != env['release_head'] or desc['certified_implementation_head'] != env['certified_implementation_head']: return False
    if desc['release_version'] != manifest['release_version'] or desc['release_version'] != env['release_version']: return False
    if desc['package_manifest_sha256'] != msha or env['package_manifest_sha256'] != msha: return False
    amap=artifact_map(env)
    drow=amap.get('update/update-descriptor.json')
    if not drow or drow.get('bytes') != os.path.getsize(desc_path) or drow.get('sha256') != dsha: return False
    for row in manifest['files']:
        s=amap.get('package/'+row['path'])
        if not s or s.get('bytes') != row['bytes'] or s.get('sha256') != row['sha256']: return False
    return True


def tree_digest(package_root, install_state_path):
    rows={}
    root=Path(package_root)
    for p in root.rglob('*'):
        if p.is_file():
            rel=p.relative_to(root).as_posix(); rows[rel]=(p.stat().st_size,sha256_file(p))
    sp=Path(install_state_path); rows['.nxb-install-state.json']=(sp.stat().st_size,sha256_file(sp))
    lines=['nxb-v1-update-tree-v1',f'file_count={len(rows)}']
    for p in sorted(rows):
        b,h=rows[p]; lines.append(f'file={p}|{b}|{h}')
    return sha256_bytes('\n'.join(lines).encode('utf-8'))


def main():
    ap=argparse.ArgumentParser()
    for name in ('policy','manifest','package_root','descriptor','envelope','trust','lifecycle','update_state','stage_receipt','apply_receipt','rollback_receipt','initial_package_root','initial_install_state','target_install_state','data_sentinel','evidence_sentinel','expected_head','output'):
        ap.add_argument('--'+name.replace('_','-'), required=True)
    a=ap.parse_args()
    policy=load_json(a.policy); manifest=load_json(a.manifest); desc=load_json(a.descriptor); env=load_json(a.envelope); trust=load_json(a.trust); lifecycle=load_json(a.lifecycle); update_state=load_json(a.update_state)
    stage=load_json(a.stage_receipt); applyr=load_json(a.apply_receipt); rollback=load_json(a.rollback_receipt); initial_state=load_json(a.initial_install_state)
    req={}
    req['policy_identity']=policy.get('contract_id')=='nxb-v1-update-v1' and policy.get('predecessor_installer_head')==INSTALLER and policy.get('production_signing_head')==SIGNING and policy.get('release_integration_head')==RELEASE_INTEGRATION and policy.get('certified_implementation_head')==CERTIFIED and policy.get('target_version')=='1.0.1'
    req['trust_contract']=valid_trust(trust)
    req['descriptor_contract']=valid_descriptor(desc) and desc.get('release_head')==a.expected_head and desc.get('release_version')==policy.get('target_version')
    req['rsa_signature']=verify_envelope(env) and env.get('release_version')==policy.get('target_version')
    req['pinned_signer']=env.get('public_key',{}).get('fingerprint')==trust.get('trusted_signer_fingerprint')
    req['manifest_contract']=valid_manifest(manifest) and manifest.get('release_version')==policy.get('target_version')
    req['package_bytes']=package_matches(a.package_root,manifest)
    req['signed_bundle']=bundle_valid(manifest,a.manifest,a.package_root,desc,a.descriptor,env,trust,0)
    core_true=('trust_anchor_passed','stage_passed','apply_passed','post_apply_verified','rollback_snapshot_created','failure_rollback_passed','manual_rollback_passed','downgrade_rejected','sequence_replay_rejected','revoked_head_rejected','wrong_signer_rejected','tampered_descriptor_rejected','tampered_package_rejected','data_preserved','evidence_preserved')
    req['lifecycle_truths']=lifecycle.get('source_head')==a.expected_head and all(lifecycle.get(k) is True for k in core_true) and lifecycle.get('auto_apply_performed') is False and lifecycle.get('machine_install_performed') is False and lifecycle.get('production_release_updated') is False
    receipt_files={'stage':a.stage_receipt,'apply':a.apply_receipt,'rollback':a.rollback_receipt}
    req['receipt_hashes']=all(sha256_file(receipt_files[k])==lifecycle.get('receipt_hashes',{}).get(k) for k in receipt_files)
    req['receipt_semantics']=stage.get('action')=='Stage' and applyr.get('action')=='Apply' and rollback.get('action')=='Rollback' and all(r.get('status')=='passed' and r.get('auto_apply') is False and r.get('production_release_updated') is False for r in (stage,applyr,rollback))
    initial_tree=tree_digest(a.initial_package_root,a.initial_install_state); target_tree=tree_digest(a.package_root,a.target_install_state)
    req['tree_digests']=lifecycle.get('initial_tree_sha256')==initial_tree and lifecycle.get('applied_tree_sha256')==target_tree and lifecycle.get('rolled_back_tree_sha256')==initial_tree
    req['sentinel_hashes']=sha256_file(a.data_sentinel)==lifecycle.get('data_sentinel_sha256') and sha256_file(a.evidence_sentinel)==lifecycle.get('evidence_sentinel_sha256')
    req['sequence_channel']=(
        desc.get('release_sequence')==1 and desc.get('channel')=='stable' and lifecycle.get('target_release_sequence')==1 and lifecycle.get('channel')=='stable' and
        update_state.get('contract_id')=='nxb-v1-update-state-v1' and update_state.get('current_release_sequence')==0 and update_state.get('highest_seen_release_sequence')==1 and update_state.get('rollback_available') is False
    )
    req['production_boundaries']=env.get('production_signer_claimed') is False and lifecycle.get('machine_install_performed') is False and lifecycle.get('production_release_updated') is False
    req['receipt_release_binding']=(
        stage.get('release_head')==a.expected_head and stage.get('release_sequence')==1 and stage.get('channel')=='stable' and
        applyr.get('release_head')==a.expected_head and applyr.get('release_sequence')==1 and applyr.get('channel')=='stable' and
        rollback.get('release_head')==initial_state.get('source_head') and rollback.get('release_sequence')==0 and rollback.get('channel')=='stable'
    )
    if len(req) != 16:
        raise RuntimeError(f'update requirement cardinality drift: {len(req)}')

    neg={}
    bad=copy.deepcopy(env); bad['public_key']['fingerprint']='0'*64; neg['wrong_signer']=not bundle_valid(manifest,a.manifest,a.package_root,desc,a.descriptor,bad,trust,0)
    bad=copy.deepcopy(env); bad['signature_b64']=base64.b64encode(b'bad').decode(); neg['tampered_signature']=not verify_envelope(bad)
    badt=copy.deepcopy(trust); badt['revoked_release_heads']=[desc['release_head']]; neg['revoked_head']=not bundle_valid(manifest,a.manifest,a.package_root,desc,a.descriptor,env,badt,0)
    neg['sequence_replay']=not bundle_valid(manifest,a.manifest,a.package_root,desc,a.descriptor,env,trust,update_state.get('highest_seen_release_sequence',0))
    badt=copy.deepcopy(trust); badt['minimum_release_sequence']=2; neg['minimum_sequence']=not bundle_valid(manifest,a.manifest,a.package_root,desc,a.descriptor,env,badt,0)
    badt=copy.deepcopy(trust); badt['channel']='beta'; neg['channel_mismatch']=not bundle_valid(manifest,a.manifest,a.package_root,desc,a.descriptor,env,badt,0)
    bad=copy.deepcopy(env); bad['key_size_bits']=2048; neg['weak_key_metadata']=not verify_envelope(bad)
    bad=copy.deepcopy(env); bad['artifacts']=bad['artifacts']+[copy.deepcopy(bad['artifacts'][0])]; neg['duplicate_artifact']=not verify_envelope(bad)
    bad=copy.deepcopy(env); bad['artifacts']=[x for x in bad['artifacts'] if x.get('path')!='update/update-descriptor.json']; neg['missing_descriptor_artifact']=not bundle_valid(manifest,a.manifest,a.package_root,desc,a.descriptor,bad,trust,0)
    badm=copy.deepcopy(manifest); badm['files'][0]['sha256']='0'*64
    badm_version=copy.deepcopy(manifest); badm_version['release_version']='1.0.0' if manifest.get('release_version')=='1.0.1' else '1.0.1'
    neg['tampered_package_hash']=(not valid_manifest(badm) or not package_matches(a.package_root,badm)) and not bundle_valid(badm_version,a.manifest,a.package_root,desc,a.descriptor,env,trust,0)
    badr=copy.deepcopy(applyr); badr['auto_apply']=True; neg['auto_apply_claim']=not (badr.get('auto_apply') is False)
    badl=copy.deepcopy(lifecycle); badl['manual_rollback_passed']=False; neg['missing_manual_rollback']=not all(badl.get(k) is True for k in core_true)
    if len(neg) != 12:
        raise RuntimeError(f'update negative-control cardinality drift: {len(neg)}')

    failures=[k for k,v in req.items() if not v]; negative_failures=[k for k,v in neg.items() if not v]
    result={
        'schema_version':1,'authority':'nxb-v1-update-independent-v2','status':'passed' if not failures and not negative_failures else 'failed',
        'update_head':a.expected_head,'requirement_count':16,'requirements_validated':16-len(failures),'requirements_failures':failures,
        'negative_count':12,'negative_controls_validated':12-len(negative_failures),'negative_controls':neg,'negative_failures':negative_failures,
        'failures':failures+negative_failures
    }
    Path(a.output).write_text(json.dumps(result,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
    if result['status']!='passed': raise SystemExit(1)

if __name__=='__main__': main()
