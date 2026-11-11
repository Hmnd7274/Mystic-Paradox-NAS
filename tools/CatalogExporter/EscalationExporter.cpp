/*
 * EscalationExporter - Dauntless 1.14.7 / CL 647472.
 *
 * Read-only DataTable export. No ProcessEvent, no hooks, no FText conversion.
 * Output: Items_Analysis/escalation_1_14_7/
 */

#define NOMINMAX
#include <windows.h>
#include <string>
#include <vector>
#include <fstream>
#include <algorithm>
#include <cstdint>
#include <cstdio>

#include "SDK.hpp"
#include "ExportPaths.hpp"

using namespace SDK;

namespace EscalationExp {

static std::wstring ResolveOutDir() {
    return ExportOutDir();
}

static std::string JsonEsc(const std::string& s) {
    std::string o;
    o.reserve(s.size() + 8);

    for (char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\r': o += "\\r";  break;
            case '\t': o += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char b[8];
                    sprintf_s(b, "\\u%04x", static_cast<unsigned char>(c));
                    o += b;
                } else {
                    o += c;
                }
        }
    }

    return o;
}

static std::string Q(const std::string& s) {
    return "\"" + JsonEsc(s) + "\"";
}

static std::string FNm(const FName& n) {
    try {
        return n.ToString();
    } catch (...) {
        return std::string();
    }
}

static std::string FStr(const FString& s) {
    try {
        return s.ToString();
    } catch (...) {
        return std::string();
    }
}

static std::string ObjectName(UObject* object) {
    if (!object) return std::string();

    try {
        return object->GetName();
    } catch (...) {
        return std::string();
    }
}

static void Status(const std::string& message) {
    OutputDebugStringA(("[EscalationExporter] " + message + "\n").c_str());

    std::ofstream f(
        ResolveOutDir() + L"\\catalog_export_status.txt",
        std::ios::app
    );

    if (f) {
        f << "[Escalation] " << message << "\n";
    }
}

static std::vector<UDataTable*> FindDataTablesByRowStruct(
    const std::string& expectedRowStructName
) {
    std::vector<UDataTable*> out;

    if (!UObject::GObjects) return out;

    UClass* dtClass = UDataTable::StaticClass();
    if (!dtClass) return out;

    const int count = UObject::GObjects->Num();

    for (int i = 0; i < count; ++i) {
        UObject* obj = UObject::GObjects->GetByIndex(i);

        if (!obj || !obj->Class) continue;
        if (!obj->IsA(dtClass)) continue;

        UDataTable* dt = static_cast<UDataTable*>(obj);

        if (!dt->RowStruct) continue;
        if (dt->RowStruct->GetName() != expectedRowStructName) continue;

        out.push_back(dt);
    }

    return out;
}

static bool RowCountIsSane(UDataTable* dt, int& outCount) {
    outCount = dt->RowMap.Num();
    return outCount >= 0 && outCount < 200000;
}

/*
 * Generic RowStruct exporter copied in style from CombatExporter.
 * Source table name and source row name are retained on every line.
 */
template <typename RowStructT, typename SerializeFn>
static int ExportByRowStruct(
    const std::string& expectedRowStructName,
    const std::wstring& outFile,
    SerializeFn serialize,
    const std::string& requiredTableName = std::string()
) {
    std::vector<UDataTable*> tables =
        FindDataTablesByRowStruct(expectedRowStructName);

    if (tables.empty()) {
        Status("no tables found with RowStruct=" + expectedRowStructName);
        return 0;
    }

    std::ofstream f(outFile, std::ios::trunc);

    if (!f) {
        Status("cannot open output file for RowStruct=" + expectedRowStructName);
        return -1;
    }

    int total = 0;

    for (UDataTable* dt : tables) {
        int rowCount = 0;

        if (!RowCountIsSane(dt, rowCount)) {
            Status("unreasonable RowMap count on " + dt->GetName());
            continue;
        }

        if (rowCount == 0) continue;

        const std::string tableName = dt->GetName();

        if (!requiredTableName.empty() && tableName != requiredTableName) {
            continue;
        }

        std::vector<std::string> rowNames;
        rowNames.reserve(rowCount);

        for (auto& Pair : dt->RowMap) {
            rowNames.push_back(FNm(Pair.Key()));
        }

        std::sort(rowNames.begin(), rowNames.end());

        int written = 0;

        for (const std::string& rowName : rowNames) {
            uint8_t* rowPtr = nullptr;

            for (auto& Pair : dt->RowMap) {
                if (FNm(Pair.Key()) == rowName) {
                    rowPtr = Pair.Value();
                    break;
                }
            }

            if (!rowPtr) continue;

            const RowStructT& row =
                *reinterpret_cast<const RowStructT*>(rowPtr);

            f << serialize(tableName, rowName, row) << "\n";
            ++written;
        }

        Status(
            "wrote " + std::to_string(written) + "/" +
            std::to_string(rowCount) + " rows from " + tableName
        );

        total += written;
    }

    f.close();

    Status(
        "ExportByRowStruct(" + expectedRowStructName +
        ") DONE total_rows=" + std::to_string(total)
    );

    return total;
}

/* -----------------------------------------------------------
 * EscalationProgressionTuning
 *
 * FText fields deliberately omitted.
 * The XP curve, season row ID, unlock IDs and referenced talent
 * table are retained for the backend conversion step.
 * ----------------------------------------------------------- */

static std::string SerializeProgressionRow(
    const std::string& tableName,
    const std::string& rowName,
    const FEscalationProgressionTuning& row
) {
    std::string o = "{";

    o += "\"sourceTable\":" + Q(tableName);
    o += ",\"rowName\":" + Q(rowName);
    o += ",\"enabled\":" + std::string(row.bEnable ? "true" : "false");
    o += ",\"seasonContext\":" +
         std::to_string(static_cast<int>(row.SeasonContext));

    o += ",\"talentsTable\":" + Q(ObjectName(row.EscalationTalentsTable));
    o += ",\"relicsTable\":" + Q(ObjectName(row.EscalationRelicsTable));

    o += ",\"persistentPowerPerEscalationLevel\":" +
         std::to_string(row.PersistentPowerPerEscalationLevel);

    o += ",\"numEscalationBuffDropsPerPlayer\":" +
         std::to_string(row.NumEscalationBuffDropsPerPlayer);

    o += ",\"breakPartExperienceDropChance\":" +
         std::to_string(row.BreakPartExperienceDropChance);

    o += ",\"capstoneCrystalExpMultiplier\":" +
         std::to_string(row.CapstoneCrystalEXPMultiplier);

    o += ",\"escalationExpRewardItem\":" +
         Q(FNm(row.EscalationExpRewardItem.RowName));

    o += ",\"escalationMaxLevelRewardItem\":" +
         Q(FNm(row.EscalationMaxLevelRewardItem.RowName));

    o += ",\"levels\":[";

    for (int i = 0; i < row.EscalationLevels.Num(); ++i) {
        if (i) o += ",";

        const auto& level = row.EscalationLevels[i];

        o += "{\"level\":" + std::to_string(level.Level);
        o += ",\"requiredExperience\":" +
             std::to_string(level.RequiredExperience);
        o += "}";
    }

    o += "]";

    o += ",\"experienceRewardsByChallengeLevel\":[";

    for (int i = 0;
         i < row.EscalationExperienceRewardsByChallengeLevel.Num();
         ++i) {
        if (i) o += ",";

        const auto& reward =
            row.EscalationExperienceRewardsByChallengeLevel[i];

        o += "{\"endOfRoundExperienceValue\":" +
             std::to_string(reward.EndOfRoundExperienceValue);

        o += ",\"breakPartExperienceValue\":" +
             std::to_string(reward.BreakPartExperienceValue);

        o += ",\"orbsReceivedFromCrystalAtMaxLevel\":" +
             std::to_string(reward.OrbsReceivedFromCrystalAtMaxLevel);

        o += "}";
    }

    o += "]";

    o += ",\"seasonalRewards\":[";

    for (int i = 0; i < row.EscalationSeasonalRewards.Num(); ++i) {
        if (i) o += ",";

        const auto& reward = row.EscalationSeasonalRewards[i];

        o += "{\"unlockLevel\":" + std::to_string(reward.UnlockLevel);
        o += ",\"unlockId\":" + Q(FStr(reward.UnlockId));
        o += ",\"rewardType\":" +
             std::to_string(static_cast<int>(reward.RewardType));

        o += ",\"statUpgrades\":[";

        for (int j = 0; j < reward.StatUpgrades.Num(); ++j) {
            if (j) o += ",";

            const auto& upgrade = reward.StatUpgrades[j];

            o += "{\"modifierName\":" + Q(FNm(upgrade.ModifierName));
            o += ",\"modifierValue\":" +
                 std::to_string(upgrade.ModifierValue);
            o += ",\"statBoostType\":" +
                 std::to_string(static_cast<int>(upgrade.StatBoostType));
            o += "}";
        }

        o += "]";

        // ItemRewards are retained as a count until their nested
        // PlayFabCatalogItemQuantity layout is separately serialized.
        o += ",\"itemRewardCount\":" +
             std::to_string(reward.ItemRewards.Num());

        o += "}";
    }

    o += "]";

    o += "}";

    return o;
}

/* -----------------------------------------------------------
 * EscalationTalentDefinition
 *
 * Rank point costs are the fields consumed by escalationProgress.ts.
 * FText and soft asset paths are not dereferenced here.
 * ----------------------------------------------------------- */

static std::string SerializeTalentRow(
    const std::string& tableName,
    const std::string& rowName,
    const FEscalationTalentDefinition& row
) {
    std::string o = "{";

    o += "\"sourceTable\":" + Q(tableName);
    o += ",\"rowName\":" + Q(rowName);
    o += ",\"talentType\":" +
         std::to_string(static_cast<int>(row.TalentType));
    o += ",\"pointsToUnlock\":" + std::to_string(row.PointsToUnlock);

    o += ",\"ranks\":[";

    for (int i = 0; i < row.Ranks.Num(); ++i) {
        if (i) o += ",";

        const auto& rank = row.Ranks[i];

        o += "{\"pointCost\":" + std::to_string(rank.PointCost);
        o += ",\"relicDropDelta\":" + std::to_string(rank.RelicDropDelta);

        o += ",\"gameplayEffectCount\":" +
             std::to_string(rank.GameplayEffects.Num());

        o += ",\"buffCount\":" +
             std::to_string(rank.Buffs.Num());

        o += ",\"relicsToUpgrade\":[";

        for (int j = 0; j < rank.EscalationRelicsToUpgrade.Num(); ++j) {
            if (j) o += ",";

            const auto& relic = rank.EscalationRelicsToUpgrade[j];

            o += "{\"id\":" + Q(FStr(relic.EscalationRelicId));
            o += ",\"numRarityLevels\":" +
                 std::to_string(relic.NumRarityLevels);
            o += "}";
        }

        o += "]";

        o += ",\"relicsToUnlock\":[";

        for (int j = 0; j < rank.EscalationRelicsToUnlock.Num(); ++j) {
            if (j) o += ",";

            o += Q(FStr(rank.EscalationRelicsToUnlock[j]));
        }

        o += "]";

        o += "}";
    }

    o += "]";
    o += "}";

    return o;
}

/* -----------------------------------------------------------
 * EscalationBuffDefinition
 * ----------------------------------------------------------- */

static std::string SerializeBuffRow(
    const std::string& tableName,
    const std::string& rowName,
    const FEscalationBuffDefinition& row
) {
    std::string o = "{";

    o += "\"sourceTable\":" + Q(tableName);
    o += ",\"rowName\":" + Q(rowName);
    o += ",\"rarity\":" +
         std::to_string(static_cast<int>(row.Rarity));

    o += ",\"unlockedByDefault\":" +
         std::string(row.UnlockedByDefault ? "true" : "false");

    o += ",\"unique\":" +
         std::string(row.Unique ? "true" : "false");

    o += ",\"dropWeight\":" + std::to_string(row.DropWeight);

    o += ",\"rankedTuning\":[";

    for (int i = 0; i < row.RankedTuning.Num(); ++i) {
        if (i) o += ",";

        const auto& tuning = row.RankedTuning[i];

        o += "{\"quality\":" + std::to_string(tuning.Quality);
        o += ",\"magnitude\":" + std::to_string(tuning.Magnitude);
        o += "}";
    }

    o += "]";

    o += ",\"customTokens\":[";

    for (int i = 0; i < row.CustomTokenizationList.Num(); ++i) {
        if (i) o += ",";

        o += Q(FStr(row.CustomTokenizationList[i].Token));
    }

    o += "]";

    o += "}";

    return o;
}

/* -----------------------------------------------------------
 * DialogTableRow
 *
 * Subtitle is FText and deliberately omitted.
 * ----------------------------------------------------------- */

static std::string SerializeDialogRow(
    const std::string& tableName,
    const std::string& rowName,
    const FDialogTableRow& row
) {
    std::string o = "{";

    o += "\"sourceTable\":" + Q(tableName);
    o += ",\"rowName\":" + Q(rowName);

    o += ",\"entries\":[";

    for (int i = 0; i < row.Entries.Num(); ++i) {
        if (i) o += ",";

        const auto& entry = row.Entries[i];

        o += "{\"audioEvent\":" + Q(ObjectName(entry.AudioEvent));

        o += ",\"subtitleDuration\":" +
             std::to_string(entry.SubtitleDuration);

        o += ",\"alwaysShowSubtitle\":" +
             std::string(entry.bAlwaysShowSubtitle ? "true" : "false");

        o += ",\"weight\":" + std::to_string(entry.Weight);

        o += "}";
    }

    o += "]";
    o += "}";

    return o;
}

/* -----------------------------------------------------------
 * PlayerJourneySeasonData
 * ----------------------------------------------------------- */

static std::string SerializePlayerJourneySeasonRow(
    const std::string& tableName,
    const std::string& rowName,
    const FPlayerJourneySeasonData& row
) {
    std::string o = "{";

    o += "\"sourceTable\":" + Q(tableName);
    o += ",\"rowName\":" + Q(rowName);
    o += ",\"eventId\":" + Q(FNm(row.EventID));

    o += ",\"factions\":[";

    for (int i = 0; i < row.Factions.Num(); ++i) {
        if (i) o += ",";

        const auto& faction = row.Factions[i];

        o += "{\"factionName\":" + Q(FNm(faction.FactionName));

        o += ",\"canReset\":" +
             std::string(faction.bCanReset ? "true" : "false");

        o += ",\"currencyGroup\":" +
             std::to_string(static_cast<int>(faction.CurrencyGroup));

        o += ",\"currencyRow\":" +
             Q(FNm(faction.Currency.RowName));

        o += ",\"factionSelectionTokenRow\":" +
             Q(FNm(faction.FactionSelectionToken.RowName));

        o += ",\"factionTalentTree\":" +
             Q(ObjectName(faction.FactionTalentTree));

        o += ",\"resetCurrencyCosts\":[";

        for (int j = 0; j < faction.ResetCurrencyCosts.Num(); ++j) {
            if (j) o += ",";

            const auto& cost = faction.ResetCurrencyCosts[j];

            o += "{\"currencyRow\":" + Q(FNm(cost.Currency.RowName));
            o += ",\"amount\":" + std::to_string(cost.Amount);
            o += "}";
        }

        o += "]";
        o += "}";
    }

    o += "]";
    o += "}";

    return o;
}

/* -----------------------------------------------------------
 * Main entry point
 * ----------------------------------------------------------- */

int RunEscalationExport() {
    const std::wstring outDir = ResolveOutDir();
    const std::wstring eDir = outDir + L"\\escalation_1_14_7";

    CreateDirectoryW(eDir.c_str(), nullptr);

    Status("starting 1.14.7 escalation DataTable export");

    const int progressionRows =
        ExportByRowStruct<FEscalationProgressionTuning>(
            "EscalationProgressionTuning",
            eDir + L"\\progression.jsonl",
            SerializeProgressionRow
        );

    const int talentRows =
        ExportByRowStruct<FEscalationTalentDefinition>(
            "EscalationTalentDefinition",
            eDir + L"\\talents.jsonl",
            SerializeTalentRow
        );

    const int buffRows =
        ExportByRowStruct<FEscalationBuffDefinition>(
            "EscalationBuffDefinition",
            eDir + L"\\buffs.jsonl",
            SerializeBuffRow
        );

    const int dialogRows =
        ExportByRowStruct<FDialogTableRow>(
            "DialogTableRow",
            eDir + L"\\dialog.jsonl",
            SerializeDialogRow,
            "escalation_dialog_table"
        );

    const int journeyRows =
        ExportByRowStruct<FPlayerJourneySeasonData>(
            "PlayerJourneySeasonData",
            eDir + L"\\player_journey_seasons.jsonl",
            SerializePlayerJourneySeasonRow
        );

    std::ofstream manifest(
        eDir + L"\\escalation_export_manifest.json",
        std::ios::trunc
    );

    if (manifest) {
        manifest << "{\n";
        manifest << "  \"gameVersion\": \"1.14.7\",\n";
        manifest << "  \"changelist\": 647472,\n";
        manifest << "  \"rowStructs\": {\n";
        manifest << "    \"EscalationProgressionTuning\": " << progressionRows << ",\n";
        manifest << "    \"EscalationTalentDefinition\": " << talentRows << ",\n";
        manifest << "    \"EscalationBuffDefinition\": " << buffRows << ",\n";
        manifest << "    \"DialogTableRow\": " << dialogRows << ",\n";
        manifest << "    \"PlayerJourneySeasonData\": " << journeyRows << "\n";
        manifest << "  }\n";
        manifest << "}\n";
    }

    const int total =
        std::max(0, progressionRows) +
        std::max(0, talentRows) +
        std::max(0, buffRows) +
        std::max(0, dialogRows) +
        std::max(0, journeyRows);

    Status(
        "DONE progression=" + std::to_string(progressionRows) +
        " talents=" + std::to_string(talentRows) +
        " buffs=" + std::to_string(buffRows) +
        " dialog=" + std::to_string(dialogRows) +
        " playerJourneySeasons=" + std::to_string(journeyRows) +
        " total=" + std::to_string(total)
    );

    if (
        progressionRows < 0 ||
        talentRows < 0 ||
        buffRows < 0 ||
        dialogRows < 0 ||
        journeyRows < 0
    ) {
        return -1;
    }

    return total;
}

} // namespace EscalationExp

int RunEscalationExport() {
    return EscalationExp::RunEscalationExport();
}