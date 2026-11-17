/*
 * Copyright (C) 2026 MysticFox / Pranav Karande (pranav158/Mystic-Paradox)
 * Licensed under the GNU Affero General Public License v3.0.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 * Additional terms under AGPLv3 Section 7 apply. See ADDITIONAL_TERMS.md.
 */

import { Router } from "express";
import { logger } from "../logger";
import { HasParadoxBackendAuth } from "../middleware/HasParadoxBackendAuth";
import { GetCharactersForUid } from "../controllers/character";
import {
    ConvertRamsToPlatinum,
    GetRamsToPlatinumOffers,
    GetRamsToPlatinumRate,
    IsRamsToPlatinumAmount,
    IsRamsToPlatinumRequestId,
} from "../controllers/ramsToPlatinum";
import { GetWallet } from "../controllers/wallet";
import { SumPlatinum } from "../platinumWallet";

export const ramsToPlatinumRouter = Router();

function PlayerUserId(req: any): string | undefined {
    if (req.AuthData?.IsGameserver === true) return undefined;
    const UserId = req.AuthData?.userId;
    if (typeof UserId !== "string" || UserId.trim().length === 0 || UserId === "INVALID") return undefined;
    return UserId;
}

ramsToPlatinumRouter.get("/rams-to-platinum", HasParadoxBackendAuth, async (req: any, res) => {
    const UserId = PlayerUserId(req);
    if (!UserId) {
        res.status(403).json({ ok: false, error: "player_auth_required" });
        return;
    }

    try {
        const Rate = GetRamsToPlatinumRate();
        const Wallet = await GetWallet(UserId);
        res.status(200).json({
            ok: true,
            rate: Rate,
            balances: {
                rams: Wallet.CURRENCY_NOTES ?? 0,
                platinum: SumPlatinum(Wallet),
            },
            offers: GetRamsToPlatinumOffers(Rate),
        });
    } catch (Err) {
        logger.error(`[RamsToPlatinum] quote failed for ${UserId}: ${String(Err)}`);
        res.status(500).json({ ok: false, error: "quote_failed" });
    }
});

ramsToPlatinumRouter.post("/rams-to-platinum/convert", HasParadoxBackendAuth, async (req: any, res) => {
    const UserId = PlayerUserId(req);
    if (!UserId) {
        res.status(403).json({ ok: false, error: "player_auth_required" });
        return;
    }

    const PlatinumAmount = req.body?.platinumAmount;
    const RequestId = req.body?.requestId;
    if (!IsRamsToPlatinumAmount(PlatinumAmount)) {
        res.status(400).json({ ok: false, error: "invalid_platinum_amount" });
        return;
    }
    if (!IsRamsToPlatinumRequestId(RequestId)) {
        res.status(400).json({ ok: false, error: "invalid_request_id" });
        return;
    }

    try {
        const Characters = await GetCharactersForUid(UserId);
        const CharacterId = Characters.length > 0 ? Characters[0].id : undefined;
        if (typeof CharacterId !== "string" || CharacterId.length === 0) {
            logger.warn(`[RamsToPlatinum] no character available for ${UserId}; conversion refused`);
            res.status(409).json({ ok: false, error: "character_not_found" });
            return;
        }

        const Rate = GetRamsToPlatinumRate();
        const Conversion = await ConvertRamsToPlatinum(UserId, CharacterId, PlatinumAmount, RequestId, { rate: Rate });
        if (!Conversion.ok) {
            if (Conversion.reason === "insufficient_balance") {
                res.status(402).json({ ok: false, error: "insufficient_rams" });
                return;
            }
            if (Conversion.reason === "conflict") {
                res.status(409).json({ ok: false, error: "transaction_conflict" });
                return;
            }
            if (Conversion.reason === "request_id_reused") {
                res.status(409).json({ ok: false, error: "request_id_reused" });
                return;
            }
            logger.error(`[RamsToPlatinum] conversion refused for ${UserId}: ${Conversion.reason}`);
            res.status(500).json({ ok: false, error: "conversion_failed" });
            return;
        }

        // Read back the persisted wallet only after the atomic debit+credit transaction has
        // committed. The aggregate helper mirrors /store/balance's 13-bucket Platinum projection.
        const Wallet = await GetWallet(UserId);
        const Balances = {
            rams: Wallet.CURRENCY_NOTES ?? 0,
            platinum: SumPlatinum(Wallet),
        };
        logger.info(`[RamsToPlatinum] ${UserId} converted ${Conversion.ramsCost} Rams -> ${Conversion.platinumAmount} Platinum (rate=1:${Conversion.rate}, txn=${RamsToPlatinumTransactionIdSafe(UserId, RequestId)})`);
        res.status(200).json({
            ok: true,
            rate: Conversion.rate,
            balances: Balances,
            converted: {
                platinumAmount: Conversion.platinumAmount,
                ramsSpent: Conversion.ramsCost,
            },
        });
    } catch (Err) {
        logger.error(`[RamsToPlatinum] conversion failed for ${UserId}: ${String(Err)}`);
        res.status(500).json({ ok: false, error: "conversion_failed" });
    }
});

function RamsToPlatinumTransactionIdSafe(UserId: string, RequestId: string): string {
    // Only the first eight characters are included in logs; the request id itself is not a credential.
    return RequestId.slice(0, 8);
}
