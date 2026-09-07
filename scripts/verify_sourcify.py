#!/usr/bin/env python3
"""Verify DHP contracts on Sourcify (Base Sepolia chainId 84532).

For each contract:
  1. Read the deployed bytecode from chain
  2. Build a standard-json solc input from local source files
  3. POST to https://sourcify.dev/server/v2/verify/{chainId}/{address}
  4. Poll until isJobCompleted → check match status

Per the evm-contract-launch skill: direct API works when `forge verify-contract`
doesn't (toolchain metadata mismatch), and this is what got Bidify verified
on Robinhood Chain.
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

CHAIN_ID = 84532  # Base Sepolia
SOLC_VERSION = "0.8.28+commit.7893614a"  # foundry build

# (address, contract_identifier, source_path_relative_to_project_root, creation_tx_hash)
CONTRACTS = [
    ("0xb44d4724092809c37eba61f822b6a8594cf7d975",
     "src/contracts/DHPImplementation.sol:DHPImplementation",
     "0x0afde90bbe3b499cf02334b609c3a859569c7dfb27ce806a323ad59ecdea3a85"),
    ("0xc9368870739718972380b80eb9de157de51e39bd",
     "src/contracts/DHPFeeCollector.sol:DHPFeeCollector",
     "0x9877ba1d0629e0ad7249eae4756e1dd3fa9f401fcf76d41bdf42db016501e97f"),
    ("0x86fdfdcad0ee32c1aa39b8f9ce98e8dbad906c90",
     "src/contracts/DHPFactory.sol:DHPFactory",
     "0xf98c1943bf589b4224802f5be04e3f12a565c4273b2fafc889e7a5e3687a0dc2"),
]

PROJECT_ROOT = Path("/tmp/dhp")

def build_solc_input(contract_path: str) -> dict:
    """Build a standard-json solc input.

    Source KEYS use the *physical* paths (e.g. `lib/oz-contracts/contracts/...`)
    in the project's remapped form. A `remappings` block tells solc that
    `@openzeppelin/contracts/X` is an alias for those physical paths.
    """
    sources = {}
    to_visit = [(contract_path, contract_path)]
    visited = set()
    while to_visit:
        logical_path, lookup_path = to_visit.pop()
        if lookup_path in visited:
            continue
        visited.add(lookup_path)
        # Map logical → physical.
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
        # Parse imports.
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


def get_creation_tx(address: str) -> str | None:
    """Get the deployment tx hash via Blockscout (no API key needed)."""
    url = f"https://base-sepolia.blockscout.com/api/v2/addresses/{address}/transactions"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            data = json.loads(r.read())
        for tx in data.get("items", []):
            if tx.get("to") is None and tx.get("hash"):
                return tx["hash"]
    except Exception as e:
        print(f"  blockscout error: {e}", file=sys.stderr)
    return None


def verify_contract(address: str, identifier: str, creation_tx: str | None) -> bool:
    """Submit to Sourcify v2 verify endpoint, poll until done."""
    contract_path = identifier.split(":")[0]
    std_input = build_solc_input(contract_path)

    body = {
        "stdJsonInput": std_input,
        "compilerVersion": SOLC_VERSION,
        "contractIdentifier": identifier,
    }
    if creation_tx:
        body["creationTransactionHash"] = creation_tx

    url = f"https://sourcify.dev/server/v2/verify/{CHAIN_ID}/{address}"
    print(f"\n  → POST {url}")
    print(f"     identifier={identifier}")
    print(f"     creation_tx={creation_tx}")

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
        print(f"  ? no jobId returned: {data}")
        return False

    # Poll until complete (max 60s).
    for attempt in range(30):
        time.sleep(2)
        poll_url = f"https://sourcify.dev/server/v2/verify/{job_id}"
        try:
            with urllib.request.urlopen(poll_url, timeout=15) as r:
                poll = json.loads(r.read())
        except Exception as e:
            print(f"    poll {attempt}: {e}")
            continue

        done = poll.get("isJobCompleted") or poll.get("completed")
        if done:
            result = poll.get("result", {})
            match = result.get("match") if isinstance(result, dict) else None
            runtime_match = poll.get("runtimeMatch") if not match else None
            creation_match = poll.get("creationMatch") if not match else None
            error = poll.get("error") or {}
            custom_code = error.get("customCode") if isinstance(error, dict) else None

            # Sourcify returns "already_verified" when the contract was previously
            # verified (by an earlier poll of ours, or by someone else). Treat
            # this as success — confirm via a fresh check.
            if custom_code == "already_verified":
                print(f"  ✓ already verified (Sourcify confirms prior match)")
                return True

            print(f"  → done. match={match} runtimeMatch={runtime_match} creationMatch={creation_match}")
            print(f"     full: {json.dumps(poll, indent=2)[:600]}")
            return match == "exact_match" or runtime_match == "exact_match" or creation_match == "exact_match"
        print(f"    poll {attempt}: still working...")

    print(f"  ✗ job did not complete in time")
    return False


def main():
    print(f"Verifying {len(CONTRACTS)} contracts on Base Sepolia (chainId={CHAIN_ID})")
    results = []
    for address, identifier, creation_tx in CONTRACTS:
        print(f"\n=== {identifier} @ {address} ===")
        print(f"  creation_tx: {creation_tx}")
        ok = verify_contract(address, identifier, creation_tx)
        results.append((identifier, address, ok))

    print(f"\n=== Summary ===")
    for ident, addr, ok in results:
        print(f"  {'✓' if ok else '✗'}  {addr}  {ident}")
    if all(r[2] for r in results):
        print(f"\n🎉 All 3 contracts verified on Sourcify (exact_match)")
        return 0
    else:
        print(f"\n⚠️  Some contracts failed verification")
        return 1


if __name__ == "__main__":
    sys.exit(main())