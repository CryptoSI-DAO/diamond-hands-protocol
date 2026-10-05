#!/usr/bin/env python3
"""Verify DHP v1.4.0 contracts on Sourcify — MAINNET chains.

Found missing during the 2026-10-05 wallet-flag investigation: DHPFactory
(0x64BE…F6929) was Sourcify-verified on Ethereum/BNB/Arc but NOT on Base or
Robinhood Chain. Unverified factory = "untrusted contract" warnings in
Coinbase Wallet/Blockaid on the exact transaction users sign to create vaults.

Same flow as verify_sourcify.py (Base Sepolia): standard-json solc input from
local sources → POST /v2/verify/{chainId}/{address} → poll job.

Creation tx hashes come from broadcast/ run-latest.json logs (DeployDHP.s.sol,
DeployMainnet.s.sol) — deterministic deploys, addresses match every chain.
"""
import json
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

SOLC_VERSION = "0.8.28+commit.7893614a"  # foundry build

PROJECT_ROOT = Path(__file__).resolve().parent.parent

FACTORY = "0x64BE13cE698684846Ae0642c1c63bb5eDE8F6929"

# (chainId, chain name, address, contract identifier, creation tx)
JOBS = [
    (
        8453, "Base", FACTORY,
        "src/contracts/DHPFactory.sol:DHPFactory",
        "0xcbe933ea581f19177ee0716b986ac9d9ae0d64eb9ebc56b1da16cf63c903f98a",
    ),
    (
        4663, "Robinhood", FACTORY,
        "src/contracts/DHPFactory.sol:DHPFactory",
        "0x6e120ede1cfcb971279f12f1b9d9e1f940bdb966bcceac0bda3a6f08df909d7f",
    ),
]


def build_solc_input(contract_path: str) -> dict:
    """Standard-json solc input; source keys are physical paths, remappings
    alias @openzeppelin/contracts and forge-std onto lib/."""
    sources = {}
    to_visit = [(contract_path, contract_path)]
    visited = set()
    while to_visit:
        logical_path, lookup_path = to_visit.pop()
        if lookup_path in visited:
            continue
        visited.add(lookup_path)
        if logical_path.startswith("@openzeppelin/contracts/"):
            rel = logical_path[len("@openzeppelin/contracts/"):]
            physical = "lib/oz-contracts/contracts/" + rel
        elif logical_path.startswith("forge-std/"):
            rel = logical_path[len("forge-std/"):]
            physical = "lib/forge-std/src/" + rel
        else:
            physical = logical_path
        abs_path = PROJECT_ROOT / physical
        if not abs_path.exists():
            raise FileNotFoundError(f"Could not resolve {logical_path} (looked at {abs_path})")
        content = abs_path.read_text()
        sources[physical] = {"content": content}
        import re
        for m in re.finditer(r'import\s+(?:\{[^}]*\}\s+from\s+)?["\']([^"\']+)["\']', content):
            imp = m.group(1)
            if imp.startswith("@openzeppelin/contracts/") or imp.startswith("forge-std/") \
                    or imp.startswith("./") or imp.startswith("../"):
                if imp.startswith("./") or imp.startswith("../"):
                    base = abs_path.parent
                    resolved_logical = str((base / imp).resolve().relative_to(PROJECT_ROOT))
                else:
                    resolved_logical = imp
                to_visit.append((resolved_logical, resolved_logical))
    return {
        "language": "Solidity",
        "sources": sources,
        "settings": {
            "optimizer": {"enabled": True, "runs": 200},
            "evmVersion": "cancun",
            "outputSelection": {
                "*": {"*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"]}
            },
            "remappings": [
                "@openzeppelin/contracts/=lib/oz-contracts/contracts/",
                "forge-std/=lib/forge-std/src/",
            ],
        },
    }


def verify_contract(chain_id: int, chain_name: str, address: str, identifier: str,
                    creation_tx: str) -> bool:
    contract_path = identifier.split(":")[0]
    std_input = build_solc_input(contract_path)

    body = {
        "stdJsonInput": std_input,
        "compilerVersion": SOLC_VERSION,
        "contractIdentifier": identifier,
        "creationTransactionHash": creation_tx,
    }

    url = f"https://sourcify.dev/server/v2/verify/{chain_id}/{address}"
    print(f"\n=== {chain_name} ({chain_id}) {identifier} @ {address} ===")
    print(f"  → POST {url}")

    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()[:500]
        print(f"  ✗ HTTP {e.code}: {body_text}")
        return False

    job_id = data.get("verificationId") or data.get("jobId") or data.get("id")
    if not job_id:
        print(f"  ? no jobId returned: {json.dumps(data)[:300]}")
        return False

    for attempt in range(30):
        time.sleep(2)
        poll_url = f"https://sourcify.dev/server/v2/verify/{job_id}"
        try:
            with urllib.request.urlopen(poll_url, timeout=15) as r:
                poll = json.loads(r.read())
        except Exception as e:
            print(f"    poll {attempt}: {e}")
            continue

        if not (poll.get("isJobCompleted") or poll.get("completed")):
            print(f"    poll {attempt}: still working...")
            continue

        # NOTE: the poll body's result fields can be empty even on success
        # (observed 2026-10-05: match/runtimeMatch/creationMatch all None but
        # the verification LANDED). Authoritative answer = fresh lookup.
        def fresh_match() -> dict:
            url = f"https://sourcify.dev/server/v2/contract/{chain_id}/{address}?fields=all"
            with urllib.request.urlopen(url, timeout=15) as r:
                return json.loads(r.read())

        error = poll.get("error") or {}
        custom_code = error.get("customCode") if isinstance(error, dict) else None
        if custom_code == "already_verified":
            print(f"  ✓ already verified (Sourcify confirms prior match)")
            return True

        result = poll.get("result", {})
        match = result.get("match") if isinstance(result, dict) else None
        runtime_match = poll.get("runtimeMatch")
        creation_match = poll.get("creationMatch")
        try:
            rec = fresh_match()
            cm, rm = rec.get("creationMatch"), rec.get("runtimeMatch")
            print(f"  → landed. creationMatch={cm} runtimeMatch={rm}")
            return cm in ("exact_match", "match") or rm in ("exact_match", "match")
        except Exception as e:
            print(f"  ? completed but lookup failed ({e}); poll said: "
                  f"match={match} runtime={runtime_match} creation={creation_match}")
            return bool(match or runtime_match or creation_match)

    print(f"  ✗ job did not complete in time")
    return False


def main():
    print(f"Verifying {len(JOBS)} contract(s) on Sourcify mainnets")
    results = []
    for chain_id, chain_name, address, identifier, creation_tx in JOBS:
        ok = verify_contract(chain_id, chain_name, address, identifier, creation_tx)
        results.append((chain_name, identifier, ok))

    print(f"\n=== Summary ===")
    failed = False
    for chain_name, ident, ok in results:
        print(f"  {'✓' if ok else '✗'}  {chain_name:10} {ident}")
        failed = failed or not ok
    if not failed:
        print(f"\n🎉 Factory now Sourcify-verified on all target chains")
        return 0
    print(f"\n⚠️  Some verifications failed")
    return 1


if __name__ == "__main__":
    sys.exit(main())
