#!/usr/bin/env python3
"""Stream created outputs from authenticated mainnet chunks, Byron to Conway.

Uses original CBOR spans, with pre-version-9 MultiAsset map/zero semantics.
This is structural extraction, not independent ledger validation. The uniform
160+output_bytes comparator is counterfactual for eras before Babbage.
Genesis initialization is handled separately by extract_genesis.py.
"""

from collections import Counter
import hashlib
from pathlib import Path
import zlib

from extract import Node, Reader, describe_output, integer, integer_map, require, sequence


ERA_NAMES = {0: "Byron", 1: "Byron", 2: "Shelley", 3: "Allegra", 4: "Mary",
             5: "Alonzo", 6: "Babbage", 7: "Conway"}
DIAGNOSTICS = ("encoded_policy_entries", "encoded_asset_entries", "zero_quantity_entries",
               "duplicate_policy_entries", "duplicate_asset_entries", "empty_policy_entries",
               "discarded_asset_entries")


def normalise_legacy_value(value):
    """Map.fromList (last entry wins), then pruneZeroMultiAsset, before v9.

    Cloned nodes retain their ORIGINAL spans, including discarded entries.
    Only the semantic map contents change; byte measurements never re-encode.
    See Mary/Value.hs decodeWithPrunning and Binary/Decoding/Decoder.hs decodeMap.
    """
    diagnostics = dict.fromkeys(DIAGNOSTICS, 0)
    if value.major == 0:
        return value, diagnostics
    pair = sequence(value, "multiasset value")
    require(len(pair) == 2, "multiasset value must have two fields")
    coin, policies = pair
    require(policies.major == 5, "policies must be a map")
    policy_map = {}
    for policy, assets in policies.value:
        require(policy.major == 2 and len(policy.value) == 28, "invalid policy ID")
        require(assets.major == 5, "assets must be a map")
        diagnostics["encoded_policy_entries"] += 1
        diagnostics["duplicate_policy_entries"] += int(policy.value in policy_map)
        diagnostics["empty_policy_entries"] += int(not assets.value)
        asset_map = {}
        for name, quantity in assets.value:
            require(name.major == 2 and len(name.value) <= 32, "invalid asset name")
            amount = integer(quantity, "quantity")
            require(amount < 2**64, "quantity exceeds uint64")
            diagnostics["encoded_asset_entries"] += 1
            diagnostics["zero_quantity_entries"] += int(amount == 0)
            diagnostics["duplicate_asset_entries"] += int(name.value in asset_map)
            asset_map[name.value] = (name, quantity)
        policy_map[policy.value] = (policy, assets, asset_map)
    kept = []
    for policy, assets, asset_map in policy_map.values():
        entries = [(name, quantity) for name, quantity in asset_map.values() if quantity.value != 0]
        if entries:
            kept.append((policy, Node(5, entries, assets.start, assets.end)))
    semantic_assets = sum(len(assets.value) for _, assets in kept)
    diagnostics["discarded_asset_entries"] = diagnostics["encoded_asset_entries"] - semantic_assets
    return Node(4, [coin, Node(5, kept, policies.start, policies.end)], value.start, value.end), diagnostics


def describe_byron_output(output):
    fields = sequence(output, "Byron output")
    require(len(fields) == 2, "Byron output must have two fields")
    address, coin_node = fields
    protected = sequence(address, "Byron CRC-protected address")
    require(len(protected) == 2, "Byron address must have two fields")
    payload, checksum = protected
    require(payload.major == 6 and payload.value[0] == 24 and payload.value[1].major == 2,
            "Byron address must wrap encoded bytes in tag 24")
    require(zlib.crc32(payload.value[1].value) == integer(checksum, "Byron address CRC"),
            "Byron address CRC mismatch")
    coin = integer(coin_node, "Byron coin")
    require(coin < 2**64, "Byron coin exceeds uint64")
    return {
        "output_bytes": output.size, "num_assets": 0, "num_policies": 0,
        "asset_name_bytes": 0, "asset_quantity_encoding_bytes": 0,
        "coin": coin, "coin_encoding_bytes": coin_node.size,
        "value_encoding_bytes": coin_node.size, "value_contribution_bytes": coin_node.size,
        "multiasset_encoding_bytes": 0, "datum_type": "none", "has_reference_script": False,
        "datum_contribution_bytes": 0, "reference_script_contribution_bytes": 0,
        "address_bytes": address.size, "address_contribution_bytes": address.size,
        "address_type": "bootstrap", "address_header_type": 8, "output_encoding": "byron_list",
        "output_framing_bytes": output.size - address.size - coin_node.size,
        "offset": output.start, "end_offset": output.end,
        **dict.fromkeys(DIAGNOSTICS, 0),
    }


def describe_historical_output(output, era_tag):
    require(era_tag in ERA_NAMES and era_tag != 0, "invalid output creation era")
    if era_tag == 1:
        return describe_byron_output(output)
    if era_tag < 6:
        require(output.major == 4, "pre-Babbage output must be a list")
        require(len(output.value) in ((2, 3) if era_tag == 5 else (2,)),
                "invalid pre-Babbage output length")
    if era_tag < 4:
        require(output.value[1].major == 0, "pre-Mary value must be coin only")
    diagnostics = dict.fromkeys(DIAGNOSTICS, 0)
    if 4 <= era_tag < 7:
        if output.major == 4:
            fields = list(output.value)
            fields[1], diagnostics = normalise_legacy_value(fields[1])
        elif output.major == 5:
            # The output's sparse record decoder rejects duplicate field keys.
            integer_map(output, "output")
            fields = []
            for key, value in output.value:
                if integer(key, "output key") == 1:
                    value, diagnostics = normalise_legacy_value(value)
                fields.append((key, value))
        else:
            raise ValueError("unsupported output encoding")
        output = Node(output.major, fields, output.start, output.end)
    row = describe_output(output)
    if era_tag == 7:
        diagnostics["encoded_policy_entries"] = row["num_policies"]
        diagnostics["encoded_asset_entries"] = row["num_assets"]
    row.update(diagnostics)
    return row


def scan_chunk(path, consume):
    """Call consume(row) per created output; return complete chunk metadata."""
    path = Path(path)
    data = path.read_bytes()
    reader = Reader(data)
    counts = dict.fromkeys(("blocks", "boundary_blocks", "transactions", "transaction_body_bytes",
                           "body_size_xor_checksum", "body_hash_xor_checksum", "invalid_transactions",
                           "ordinary_outputs_skipped_in_invalid_transactions", "collateral_return_outputs",
                           "created_outputs"), 0)
    era_blocks, era_outputs, diagnostics = Counter(), Counter(), Counter()
    first_slot = last_slot = first_block = last_block = None
    while reader.pos < len(data):
        block = reader.read()
        outer = sequence(block, "hard-fork block")
        require(len(outer) == 2, "hard-fork block must be a pair")
        era = integer(outer[0], "era tag")
        require(era in ERA_NAMES, f"unsupported era tag {era}")
        parts = sequence(outer[1], "block")
        era_blocks[ERA_NAMES[era]] += 1
        counts["blocks"] += 1
        if era < 2:
            require(len(parts) == 3, "Byron block must have three fields")
            header = sequence(parts[0], "Byron header")
            require(len(header) == 5, "Byron header must have five fields")
            consensus = sequence(header[3], "Byron consensus data")
            if era == 0:
                counts["boundary_blocks"] += 1
                continue
            require(len(consensus) == 4, "Byron consensus data must have four fields")
            slot_id = sequence(consensus[0], "Byron slot ID")
            require(len(slot_id) == 2, "Byron slot ID must have two fields")
            # The pinned mainnet genesis uses 21600 slots per Byron epoch.
            slot = 21600 * integer(slot_id[0], "epoch") + integer(slot_id[1], "epoch slot")
            difficulty = sequence(consensus[2], "Byron chain difficulty")
            require(len(difficulty) == 1, "Byron difficulty must be a singleton")
            block_number = integer(difficulty[0], "Byron block number")
            body = sequence(parts[1], "Byron block body")
            require(len(body) == 4, "Byron block body must have four fields")
            bodies = []
            for auxiliary in sequence(body[0], "Byron transaction payload"):
                auxiliary_fields = sequence(auxiliary, "Byron TxAux")
                require(len(auxiliary_fields) == 2, "Byron TxAux must have two fields")
                bodies.append(auxiliary_fields[0])
            invalid = set()
        else:
            require(len(parts) == (4 if era < 5 else 5), "unexpected block field count")
            header = sequence(parts[0], "header")
            require(len(header) == 2, "header must be a pair")
            header_body = sequence(header[0], "header body")
            require(len(header_body) == (15 if era < 6 else 10), "unexpected header body length")
            block_number = integer(header_body[0], "block number")
            slot = integer(header_body[1], "slot")
            bodies = sequence(parts[1], "transaction bodies")
            invalid_list = []
            if era >= 5:
                invalid_node = parts[4]
                if invalid_node.major == 6:
                    require(invalid_node.value[0] == 258, "unexpected invalid-index set tag")
                    invalid_node = invalid_node.value[1]
                invalid_list = [integer(n, "invalid transaction index")
                                for n in sequence(invalid_node, "invalid transactions")]
            invalid = set(invalid_list)
            require(len(invalid) == len(invalid_list), "duplicate invalid transaction index")
            require(all(i < len(bodies) for i in invalid), "invalid transaction index out of range")
        first_slot = slot if first_slot is None else min(first_slot, slot)
        last_slot = slot if last_slot is None else max(last_slot, slot)
        first_block = block_number if first_block is None else min(first_block, block_number)
        last_block = block_number if last_block is None else max(last_block, block_number)
        counts["invalid_transactions"] += len(invalid)
        for transaction_index, body in enumerate(bodies):
            if era == 1:
                fields = sequence(body, "Byron transaction")
                require(len(fields) == 3, "Byron transaction must have three fields")
                ordinary = sequence(fields[1], "Byron outputs")
            else:
                fields, _ = integer_map(body, "transaction body")
                require(1 in fields, "transaction body missing outputs")
                ordinary = sequence(fields[1], "outputs")
            digest = hashlib.blake2b(data[body.start:body.end], digest_size=32).digest()
            counts["transaction_body_bytes"] += body.size
            counts["body_size_xor_checksum"] ^= body.size
            digest_checksum = 0
            for byte in digest:
                digest_checksum = (digest_checksum * 131 + byte) & (2**64 - 1)
            counts["body_hash_xor_checksum"] ^= digest_checksum
            is_invalid = transaction_index in invalid
            if is_invalid:
                counts["ordinary_outputs_skipped_in_invalid_transactions"] += len(ordinary)
                outputs = [(len(ordinary), fields[16])] if era >= 6 and 16 in fields else []
                counts["collateral_return_outputs"] += len(outputs)
            else:
                outputs = enumerate(ordinary)
            for output_index, output in outputs:
                row = describe_historical_output(output, era)
                row.update({"era": ERA_NAMES[era], "era_tag": era, "chunk": path.name,
                            "block_number": block_number, "slot": slot,
                            "transaction_index": transaction_index,
                            # Byron's ledger TxId hashes a canonical re-encoding,
                            # so the received-body hash is not asserted as its ID.
                            "txid": digest.hex() if era >= 2 else None,
                            "raw_transaction_body_hash": digest.hex(),
                            "output_index": output_index, "is_collateral_return": is_invalid,
                            "population": "transaction_created", "size_provenance": "original_wire_bytes"})
                consume(row)
                counts["created_outputs"] += 1
                era_outputs[ERA_NAMES[era]] += 1
                for key in DIAGNOSTICS:
                    diagnostics[key] += row[key]
        counts["transactions"] += len(bodies)
    require(reader.pos == len(data), "chunk was not fully consumed")
    return {"path": str(path), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            **counts, "era_blocks": dict(era_blocks), "era_outputs": dict(era_outputs),
            "encoding_diagnostics": dict(diagnostics),
            "first_slot": first_slot, "last_slot": last_slot,
            "first_block": first_block, "last_block": last_block,
            "fully_consumed": True,
            "scope": "Original wire output creations from authenticated blocks; not a UTxO census or ledger validation."}
