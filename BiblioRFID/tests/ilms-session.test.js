import test from "node:test";
import assert from "node:assert/strict";
import { IlmsClientError } from "../lib/ilms-circulation-client.js";
import { IlmsSessionStore } from "../lib/ilms-session.js";

const GATEWAY = "https://gateway.example.org";
const ACCOUNT = "11111111-1111-4111-8111-111111111111";
const LIBRARY = "22222222-2222-4222-8222-222222222222";
const OTHER = "33333333-3333-4333-8333-333333333333";

const NOW = Date.UTC(2026, 9, 15, 12, 0, 0);
const now = () => NOW;

/** Jeton de forme reelle : la session lit son echeance dans la revendication `exp`. */
function jwt(expSeconds) {
  const part = value => Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
  return `${part({alg: "none"})}.${part({exp: expSeconds})}.c2ln`;
}

const VALID = jwt(Math.floor(NOW / 1000) + 3600);

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {status, headers: {"Content-Type": "application/json"}});
}

const credentials = {
  gatewayUrl: GATEWAY,
  username: "operateur",
  password: "secret",
  clientId: "test-client",
  clientSecret: "secret",
};

/**
 * Serveur par defaut : les trois etapes du contrat, dans l'ordre. Les options
 * remplacent une etape pour eprouver un refus precis.
 */
function transport(overrides = {}) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({url, init});
    const path = new URL(url).pathname;
    if (overrides[path]) return overrides[path](init);
    if (path === "/auth-service/oauth/token") {
      return json({token_type: "bearer", expires_in: 300, access_token: "bootstrap.token.value"});
    }
    if (path === "/auth-service/api/v1/auth/login") {
      return json({access_token: {type: "Bearer", token: VALID}, user: {id: ACCOUNT}});
    }
    if (path === "/library-service/api/v1/libraries") {
      return json([{id: LIBRARY, name: "Bibliotheque ZTF"}]);
    }
    return json({}, 404);
  };
  return {calls, fetchImpl};
}

function store(overrides) {
  const {calls, fetchImpl} = transport(overrides);
  return {calls, session: new IlmsSessionStore({fetchImpl, now})};
}

test("signs in through the three portal stages, in order, and auto-selects a single library", async () => {
  const {calls, session} = store();
  const state = await session.signIn(credentials);

  assert.deepEqual(calls.map(call => new URL(call.url).pathname), [
    "/auth-service/oauth/token",
    "/auth-service/api/v1/auth/login",
    "/library-service/api/v1/libraries",
  ]);
  assert.equal(state.signed_in, true);
  assert.equal(state.active, true);
  assert.equal(state.account_id, ACCOUNT);
  assert.equal(state.library_id, LIBRARY);
  assert.deepEqual(state.libraries, [{id: LIBRARY, name: "Bibliotheque ZTF"}]);
});

test("the OAuth stage carries Basic credentials and the client_credentials grant", async () => {
  const {calls, session} = store();
  await session.signIn(credentials);
  const oauth = calls[0].init;

  assert.equal(oauth.method, "POST");
  assert.equal(oauth.headers.Authorization, `Basic ${Buffer.from("test-client:secret").toString("base64")}`);
  assert.equal(oauth.headers["Content-Type"], "application/x-www-form-urlencoded");
  assert.equal(oauth.body, "grant_type=client_credentials&scope=read+write");
});

test("the user token, not the bootstrap token, authorizes the library listing", async () => {
  const {calls, session} = store();
  await session.signIn(credentials);

  assert.equal(calls[1].init.headers.Authorization, "Bearer bootstrap.token.value");
  assert.equal(calls[2].init.headers.Authorization, `Bearer ${VALID}`);
});

test("never follows a redirect during sign-in", async () => {
  const {calls, session} = store();
  await session.signIn(credentials);
  for (const call of calls) assert.equal(call.init.redirect, "error");
});

test("state never carries the token, while the circulation session does", async () => {
  const {session} = store();
  const state = await session.signIn(credentials);

  assert.equal(JSON.stringify(state).includes(VALID), false);
  assert.equal(session.session.accessToken, VALID);
  assert.deepEqual(Object.keys(session.session).sort(),
    ["accessToken", "accountId", "gatewayUrl", "libraryId"]);
});

test("several libraries leave the choice to the operator", async () => {
  const {session} = store({
    "/library-service/api/v1/libraries": () => json([
      {id: LIBRARY, name: "Bibliotheque ZTF"},
      {id: OTHER, name: "Annexe"},
    ]),
  });
  const state = await session.signIn(credentials);

  assert.equal(state.library_id, null);
  // Portee incomplete : le client de circulation ne doit pas la recevoir.
  assert.equal(session.session, null);

  session.selectLibrary(OTHER);
  assert.equal(session.session.libraryId, OTHER);
});

test("refuses a library the server did not grant", async () => {
  const {session} = store();
  await session.signIn(credentials);
  assert.throws(() => session.selectLibrary(OTHER), error => error instanceof IlmsClientError && error.code === "scope");
  assert.throws(() => session.selectLibrary("not-a-uuid"), error => error.code === "scope");
});

test("a password awaiting renewal is named, not retried", async () => {
  const {session} = store({
    "/auth-service/api/v1/auth/login": () => json({access_token: {type: "Password-Token", token: VALID}, user: {id: ACCOUNT}}),
  });
  await assert.rejects(session.signIn(credentials),
    error => error instanceof IlmsClientError && error.code === "password_change");
  assert.equal(session.signedIn, false);
});

test("a flagged account is refused even when the token type is right", async () => {
  const {session} = store({
    "/auth-service/api/v1/auth/login": () =>
      json({access_token: {type: "Bearer", token: VALID}, user: {id: ACCOUNT, password_change_required: true}}),
  });
  await assert.rejects(session.signIn(credentials), error => error.code === "password_change");
});

test("an account without any library cannot drive a station", async () => {
  const {session} = store({"/library-service/api/v1/libraries": () => json([])});
  await assert.rejects(session.signIn(credentials), error => error.code === "no_library");
  assert.equal(session.signedIn, false);
});

test("an expired token is refused at sign-in rather than carried", async () => {
  const {session} = store({
    "/auth-service/api/v1/auth/login": () =>
      json({access_token: {type: "Bearer", token: jwt(Math.floor(NOW / 1000) - 1)}, user: {id: ACCOUNT}}),
  });
  await assert.rejects(session.signIn(credentials), error => error.code === "auth" && error.status === 401);
});

test("a session whose token has expired stays visible but stops authorizing", async () => {
  const clock = {value: NOW};
  const {fetchImpl} = transport();
  const session = new IlmsSessionStore({fetchImpl, now: () => clock.value});
  await session.signIn(credentials);

  clock.value = NOW + 3600 * 1000 + 1;
  assert.equal(session.signedIn, true);
  assert.equal(session.active, false);
  assert.equal(session.state.active, false);
  // Jeton vide : le client de circulation refusera, au lieu d'envoyer un
  // en-tete qu'ILMS rejetterait.
  assert.equal(session.session.accessToken, "");
});

test("a sign-in refusal names its stage and never speaks of the journal", async () => {
  const {session} = store({"/auth-service/api/v1/auth/login": () => json({error: "bad request"}, 400)});
  await assert.rejects(session.signIn(credentials), error => {
    assert.equal(error.code, "signin");
    assert.equal(error.status, 400);
    assert.equal(error.stage, "login");
    // `denied` parle du journal : hors de propos pendant une connexion.
    assert.equal(error.message.includes("journal"), false);
    return true;
  });
});

test("each of the three stages is named when it is the one that fails", async () => {
  const stages = [
    ["/auth-service/oauth/token", "oauth"],
    ["/auth-service/api/v1/auth/login", "login"],
    ["/library-service/api/v1/libraries", "libraries"],
  ];
  for (const [path, stage] of stages) {
    const {session} = store({[path]: () => json({error: "no"}, 500)});
    await assert.rejects(session.signIn(credentials), error => error.stage === stage, stage);
  }
});

test("an account without a library points at the library stage, not the password", async () => {
  const {session} = store({"/library-service/api/v1/libraries": () => json([])});
  await assert.rejects(session.signIn(credentials),
    error => error.code === "no_library" && error.stage === "libraries");
});

test("a wrong password is reported as an authentication refusal, not a retryable outage", async () => {
  const {session} = store({"/auth-service/api/v1/auth/login": () => json({error: "bad"}, 401)});
  await assert.rejects(session.signIn(credentials), error => error.code === "auth" && error.status === 401);
});

test("an HTML answer is refused: a login page is not a session", async () => {
  const {session} = store({
    "/auth-service/api/v1/auth/login": () => new Response("<html>login</html>",
      {status: 200, headers: {"Content-Type": "text/html"}}),
  });
  await assert.rejects(session.signIn(credentials), error => error.code === "response");
});

test("refuses an origin with credentials, a path, or a plain-text host", async () => {
  const {session} = store();
  for (const gatewayUrl of [
    "https://user:pass@gateway.example.org",
    "https://gateway.example.org/library-service",
    "http://gateway.example.org",
    "ftp://gateway.example.org",
    "not a url",
  ]) {
    await assert.rejects(session.signIn({...credentials, gatewayUrl}),
      error => error instanceof IlmsClientError && error.code === "scope", gatewayUrl);
  }
});

test("accepts loopback over plain HTTP, for a station talking to a local gateway", async () => {
  const {fetchImpl} = transport();
  const session = new IlmsSessionStore({fetchImpl, now});
  const state = await session.signIn({...credentials, gatewayUrl: "http://127.0.0.1:8080"});
  assert.equal(state.gateway_url, "http://127.0.0.1:8080");
});

test("refuses empty or oversized credentials before reaching the network", async () => {
  const {calls, session} = store();
  for (const override of [
    {username: "   "},
    {username: "x".repeat(256)},
    {password: ""},
    {clientId: "with:colon"},
    {clientSecret: ""},
  ]) {
    await assert.rejects(session.signIn({...credentials, ...override}),
      error => error instanceof IlmsClientError && error.code === "input", JSON.stringify(override));
  }
  assert.equal(calls.length, 0);
});

test("signing out drops the token and the library", async () => {
  const {session} = store();
  await session.signIn(credentials);
  session.signOut();

  assert.equal(session.signedIn, false);
  assert.equal(session.session, null);
  assert.deepEqual(session.state.libraries, []);
  assert.equal(session.state.gateway_url, null);
});

test("a reply from a session already signed out is discarded", async () => {
  let release;
  const pending = new Promise(resolve => { release = resolve; });
  const {fetchImpl} = transport({
    "/library-service/api/v1/libraries": async () => {
      await pending;
      return json([{id: LIBRARY, name: "Bibliotheque ZTF"}]);
    },
  });
  const session = new IlmsSessionStore({fetchImpl, now});

  const attempt = session.signIn(credentials);
  session.signOut();
  release();

  await assert.rejects(attempt, error => error instanceof IlmsClientError && error.code === "scope");
  assert.equal(session.signedIn, false);
});
