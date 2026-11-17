/*
 * Copyright (C) 2026 MysticFox / Pranav Karande (pranav158/Mystic-Paradox)
 * Licensed under the GNU Affero General Public License v3.0.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 */

import crypto from "node:crypto";
import { RunInventoryTransaction, InventoryTransactionConflictError, InventoryTransactionMismatchError } from "./inventory";
import { InsufficientBalanceError, IsPrestigeGatedReward } from "./wallet";
import { logger } from "../logger";

export const DEFAULT_RAMS_TO_PLATINUM_RATE = 15;
export const RAMS_TO_PLATINUM_AMOUNTS = [100, 500, 1000, 5000] as const;
export const RAMS_CURRENCY_ID = "CURRENCY_NOTES";
export const PLATINUM_CURRENCY_ID = "CURRENCY_PLATINUM_UNIV";

export type RamsToPlatinumAmount = typeof RAMS_TO_PLATINUM_AMOUNTS[number];
export type RamsToPlatinumOffer = { platinumAmount: RamsToPlatinumAmount; ramsCost: number };

export function ParseRamsToPlatinumRate(RawRate: string | undefined): number {
    if (RawRate === undefined || RawRate.trim() === "") return DEFAULT_RAMS_TO_PLATINUM_RATE;

    const Rate = Number(RawRate.trim());
    const MaximumRate = Math.floor(Number.MAX_SAFE_INTEGER / Math.max(...RAMS_TO_PLATINUM_AMOUNTS));
    if (!Number.isSafeInteger(Rate) || Rate <= 0 || Rate > MaximumRate) {
        return DEFAULT_RAMS_TO_PLATINUM_RATE;
    }
    return Rate;
}

export function GetRamsToPlatinumRate(): number {
    const RawRate = process.env.RAMS_TO_PLATINUM_RATE;
    const Rate = ParseRamsToPlatinumRate(RawRate);
    if (RawRate !== undefined && RawRate.trim() !== "" && Number(RawRate.trim()) !== Rate) {
        logger.error(`[RamsToPlatinum] Invalid RAMS_TO_PLATINUM_RATE='${RawRate}', using ${DEFAULT_RAMS_TO_PLATINUM_RATE}`);
    }
    return Rate;
}

export function GetRamsToPlatinumOffers(Rate = GetRamsToPlatinumRate()): RamsToPlatinumOffer[] {
    const SafeRate = ParseRamsToPlatinumRate(String(Rate));
    return RAMS_TO_PLATINUM_AMOUNTS.map((PlatinumAmount) => ({
        platinumAmount: PlatinumAmount,
        ramsCost: PlatinumAmount * SafeRate,
    }));
}

export function IsRamsToPlatinumAmount(Value: unknown): Value is RamsToPlatinumAmount {
    return typeof Value === "number"
        && Number.isSafeInteger(Value)
        && (RAMS_TO_PLATINUM_AMOUNTS as readonly number[]).includes(Value);
}

export function IsRamsToPlatinumRequestId(Value: unknown): Value is string {
    return typeof Value === "string" && /^[a-f0-9]{32}$/i.test(Value);
}

// One user-scoped idempotency key per explicit menu confirmation. A retransmitted HTTP request
// with the same id and amount replays the committed inventory transaction; a changed amount is
// rejected by RunInventoryTransaction's request-hash binding.
export function RamsToPlatinumTransactionId(UserId: string, RequestId: string): string {
    return crypto.createHash("sha256")
        .update(`rams-to-platinum:${UserId}:${RequestId.toLowerCase()}`)
        .digest("hex")
        .slice(0, 32)
        .toUpperCase();
}

export type RamsToPlatinumPurchaseResult =
    | { ok: true; platinumAmount: RamsToPlatinumAmount; ramsCost: number; rate: number; result: any }
    | { ok: false; reason: "invalid_amount" | "invalid_request_id" | "insufficient_balance" | "conflict" | "request_id_reused" | "transaction_failed" };

export type RamsToPlatinumPurchaseOptions = {
    rate?: number;
    runTransaction?: typeof RunInventoryTransaction;
};

export async function ConvertRamsToPlatinum(
    UserId: string,
    CharacterId: string,
    PlatinumAmountInput: unknown,
    RequestIdInput: unknown,
    Options: RamsToPlatinumPurchaseOptions = {}
): Promise<RamsToPlatinumPurchaseResult> {
    if (!IsRamsToPlatinumAmount(PlatinumAmountInput)) return { ok: false, reason: "invalid_amount" };
    if (!IsRamsToPlatinumRequestId(RequestIdInput)) return { ok: false, reason: "invalid_request_id" };
    if (typeof UserId !== "string" || UserId.trim().length === 0 || UserId === "INVALID"
        || typeof CharacterId !== "string" || CharacterId.trim().length === 0) {
        return { ok: false, reason: "transaction_failed" };
    }

    const Rate = ParseRamsToPlatinumRate(String(Options.rate ?? GetRamsToPlatinumRate()));
    const RamsCost = PlatinumAmountInput * Rate;

    // Platinum Universal is a normal wallet credit (not a prestige reward). Fail closed if a
    // future game-data change ever marks it as prestige-funded: an exchange must never bypass
    // the prestige funding rules used by all other CURRENCY_* grants.
    if (IsPrestigeGatedReward(PLATINUM_CURRENCY_ID)) {
        logger.error("[RamsToPlatinum] CURRENCY_PLATINUM_UNIV became prestige-gated; conversion refused");
        return { ok: false, reason: "transaction_failed" };
    }

    const TransactionId = RamsToPlatinumTransactionId(UserId, RequestIdInput);
    try {
        const Result = await (Options.runTransaction ?? RunInventoryTransaction)(
            UserId,
            CharacterId,
            TransactionId,
            [],
            [{ catalogId: PLATINUM_CURRENCY_ID, quantity: PlatinumAmountInput }],
            [],
            [{ catalogId: RAMS_CURRENCY_ID, quantity: RamsCost }],
            [],
            {
                diagnosticLabel: `rams-to-platinum:${PlatinumAmountInput}`,
                economy: { source: "STORE", storeSkuId: `rams_to_platinum_${PlatinumAmountInput}` },
            }
        );

        if (!Result) return { ok: false, reason: "transaction_failed" };
        return { ok: true, platinumAmount: PlatinumAmountInput, ramsCost: RamsCost, rate: Rate, result: Result };
    } catch (Err) {
        if (Err instanceof InsufficientBalanceError) return { ok: false, reason: "insufficient_balance" };
        if (Err instanceof InventoryTransactionConflictError) return { ok: false, reason: "conflict" };
        if (Err instanceof InventoryTransactionMismatchError) return { ok: false, reason: "request_id_reused" };
        throw Err;
    }
}
