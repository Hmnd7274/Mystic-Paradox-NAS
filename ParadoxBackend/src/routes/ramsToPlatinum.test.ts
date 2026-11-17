import assert from "node:assert/strict";
import test from "node:test";
import { IsPlayerBearerRequest } from "./ramsToPlatinum";

test("currency conversion requires a real player Bearer without a gameserver key", () => {
    assert.equal(IsPlayerBearerRequest({
        headers: { authorization: "Bearer signed-player-jwt" },
        AuthData: { userId: "player-1" },
    }), true);

    assert.equal(IsPlayerBearerRequest({
        headers: { authorization: "Bearer signed-player-jwt", "x-mysticparadox-gameserver-apikey": "service-key" },
        AuthData: { userId: "player-1", IsGameserver: true },
    }), false);

    assert.equal(IsPlayerBearerRequest({
        headers: {},
        AuthData: { userId: "mystpax", IsGameserver: true },
    }), false);

    assert.equal(IsPlayerBearerRequest({
        headers: { authorization: "Basic abc" },
        AuthData: { userId: "player-1" },
    }), false);
});
