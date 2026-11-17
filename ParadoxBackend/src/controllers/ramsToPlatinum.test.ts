/*
 * Copyright (C) 2026 MysticFox / Pranav Karande (pranav158/Mystic-Paradox)
 * Licensed under the GNU Affero General Public License v3.0.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 */

import assert from "node:assert/strict";
import test from "node:test";
import {
    ConvertRamsToPlatinum,
    GetRamsToPlatinumOffers,
    GetRamsToPlatinumRate,
    IsRamsToPlatinumAmount,
    IsRamsToPlatinumRequestId,
    ParseRamsToPlatinumRate,
    PLATINUM_CURRENCY_ID,
    RAMS_CURRENCY_ID,
    RamsToPlatinumTransactionId,
} from "./ramsToPlatinum";
import { InsufficientBalanceError, IsPrestigeGatedReward } from "./wallet";
import { InventoryTransactionConflictError, InventoryTransactionMismatchError, RunInventoryTransaction } from "./inventory";

test("Rams-to-Platinum uses a configurable rate and defaults to 15 Rams per Platinum", () => {
    assert.equal(ParseRamsToPlatinumRate(undefined), 15);
    assert.equal(ParseRamsToPlatinumRate(""), 15);
    assert.equal(ParseRamsToPlatinumRate("  "), 15);
    assert.equal(ParseRamsToPlatinumRate("20"), 20);
    assert.equal(ParseRamsToPlatinumRate("0"), 15);
    assert.equal(ParseRamsToPlatinumRate("-5"), 15);
    assert.equal(ParseRamsToPlatinumRate("1.5"), 15);
    assert.equal(ParseRamsToPlatinumRate("Infinity"), 15);
    assert.equal(ParseRamsToPlatinumRate("not-a-number"), 15);
    assert.equal(GetRamsToPlatinumRate(), ParseRamsToPlatinumRate(process.env.RAMS_TO_PLATINUM_RATE));
});

test("Rams-to-Platinum quotes are calculated from the active server rate", () => {
    assert.deepEqual(GetRamsToPlatinumOffers(15), [
        { platinumAmount: 100, ramsCost: 1500 },
        { platinumAmount: 500, ramsCost: 7500 },
        { platinumAmount: 1000, ramsCost: 15000 },
        { platinumAmount: 5000, ramsCost: 75000 },
    ]);
    assert.deepEqual(GetRamsToPlatinumOffers(20)[0], { platinumAmount: 100, ramsCost: 2000 });
});

test("only the four menu offers and a 32-character request id are accepted", () => {
    assert.equal(IsRamsToPlatinumAmount(100), true);
    assert.equal(IsRamsToPlatinumAmount(5000), true);
    assert.equal(IsRamsToPlatinumAmount(101), false);
    assert.equal(IsRamsToPlatinumAmount("500"), false);
    assert.equal(IsRamsToPlatinumAmount(Number.MAX_SAFE_INTEGER), false);
    assert.equal(IsRamsToPlatinumRequestId("0123456789abcdef0123456789abcdef"), true);
    assert.equal(IsRamsToPlatinumRequestId("not-a-request-id"), false);
});

test("conversion idempotency keys are deterministic and scoped to the authenticated account", () => {
    const RequestId = "0123456789abcdef0123456789abcdef";
    const First = RamsToPlatinumTransactionId("user-a", RequestId);
    assert.equal(First, RamsToPlatinumTransactionId("user-a", RequestId.toUpperCase()));
    assert.equal(First.length, 32);
    assert.match(First, /^[A-F0-9]{32}$/);
    assert.notEqual(First, RamsToPlatinumTransactionId("user-b", RequestId));
    assert.notEqual(First, RamsToPlatinumTransactionId("user-a", "1123456789abcdef0123456789abcdef"));
});

test("conversion atomically spends Rams and credits Universal Platinum", async () => {
    let Captured: unknown[] | undefined;
    const Result = await ConvertRamsToPlatinum("user-1", "character-1", 500, "0123456789abcdef0123456789abcdef", {
        rate: 15,
        runTransaction: (async (...Args: unknown[]) => {
            Captured = Args;
            return { updatedStackedItems: [] };
        }) as typeof RunInventoryTransaction,
    });

    assert.equal(Result.ok, true);
    if (!Result.ok) return;
    assert.equal(Result.platinumAmount, 500);
    assert.equal(Result.ramsCost, 7500);
    assert.equal(Result.rate, 15);
    assert.ok(Captured);
    assert.equal(Captured[0], "user-1");
    assert.equal(Captured[1], "character-1");
    assert.equal(Captured[2], RamsToPlatinumTransactionId("user-1", "0123456789abcdef0123456789abcdef"));
    assert.deepEqual(Captured[3], []);
    assert.deepEqual(Captured[4], [{ catalogId: PLATINUM_CURRENCY_ID, quantity: 500 }]);
    assert.deepEqual(Captured[5], []);
    assert.deepEqual(Captured[6], [{ catalogId: RAMS_CURRENCY_ID, quantity: 7500 }]);
    assert.deepEqual(Captured[7], []);
    assert.deepEqual(Captured[8], {
        diagnosticLabel: "rams-to-platinum:500",
        economy: { source: "STORE", storeSkuId: "rams_to_platinum_500" },
    });
});

test("invalid package or id is refused before starting a transaction", async () => {
    let Called = false;
    const runTransaction = (async () => { Called = true; return {}; }) as typeof RunInventoryTransaction;
    assert.deepEqual(
        await ConvertRamsToPlatinum("user-1", "character-1", 101, "0123456789abcdef0123456789abcdef", { runTransaction }),
        { ok: false, reason: "invalid_amount" }
    );
    assert.deepEqual(
        await ConvertRamsToPlatinum("user-1", "character-1", 100, "bad", { runTransaction }),
        { ok: false, reason: "invalid_request_id" }
    );
    assert.equal(Called, false);
});

test("insufficient Rams, concurrency conflicts and reused ids are mapped safely", async () => {
    const RequestId = "0123456789abcdef0123456789abcdef";
    const Insufficient = await ConvertRamsToPlatinum("user-1", "character-1", 100, RequestId, {
        runTransaction: (async () => { throw new InsufficientBalanceError("user-1", RAMS_CURRENCY_ID, -1500, 0); }) as typeof RunInventoryTransaction,
    });
    assert.deepEqual(Insufficient, { ok: false, reason: "insufficient_balance" });

    const Conflict = await ConvertRamsToPlatinum("user-1", "character-1", 100, RequestId, {
        runTransaction: (async () => { throw new InventoryTransactionConflictError("txn"); }) as typeof RunInventoryTransaction,
    });
    assert.deepEqual(Conflict, { ok: false, reason: "conflict" });

    const Reused = await ConvertRamsToPlatinum("user-1", "character-1", 500, RequestId, {
        runTransaction: (async () => { throw new InventoryTransactionMismatchError("txn"); }) as typeof RunInventoryTransaction,
    });
    assert.deepEqual(Reused, { ok: false, reason: "request_id_reused" });
});

test("Universal Platinum is not a prestige-gated reward currency", () => {
    assert.equal(IsPrestigeGatedReward(PLATINUM_CURRENCY_ID), false);
});
