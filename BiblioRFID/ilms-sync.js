import { IlmsCirculationClient, IlmsClientError } from "./lib/ilms-circulation-client.js";
import { IlmsCirculationJournal } from "./lib/ilms-circulation-journal.js";

async function input() {
  const chunks = []; let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length; if (size > 4096) throw new IlmsClientError("input"); chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { throw new IlmsClientError("input"); }
}
async function main() {
  const [command, argument, extra] = process.argv.slice(2);
  if (!command || command === "help") {
    process.stdout.write("ILMS : resolve-member, resolve-copy, enqueue, list, retry <UUID>, discard <UUID> --confirm-local-discard.\n"
      + "Configuration locale : ILMS_GATEWAY_URL, ILMS_ACCOUNT_ID, ILMS_LIBRARY_ID, ILMS_JOURNAL_PATH ; ILMS_ACCESS_TOKEN pour HTTP uniquement.\n"
      + "Tags/demandes JSON sur stdin. Aucun renvoi automatique, aucune importation de l'ancienne base.\n"); return;
  }
  if (!["resolve-member", "resolve-copy", "enqueue", "list", "retry", "discard"].includes(command)
    || ((command === "retry" || command === "discard") ? !argument : argument !== undefined)
    || (command === "discard" ? extra !== "--confirm-local-discard" : extra !== undefined)
    || process.argv.length > (command === "discard" ? 5 : command === "retry" ? 4 : 3)) throw new IlmsClientError("input");
  if (!process.env.ILMS_JOURNAL_PATH || process.env.ILMS_JOURNAL_PATH === ":memory:") throw new IlmsClientError("storage");
  const journal = new IlmsCirculationJournal(process.env.ILMS_JOURNAL_PATH);
  try {
    const client = new IlmsCirculationClient({journal, getSession: () => ({gatewayUrl: process.env.ILMS_GATEWAY_URL,
      accountId: process.env.ILMS_ACCOUNT_ID, libraryId: process.env.ILMS_LIBRARY_ID, accessToken: process.env.ILMS_ACCESS_TOKEN})});
    let result;
    if (command === "list") result = client.list();
    else if (command === "enqueue") result = {saved: true, accepted_by_ilms: false, entry: client.enqueue(await input())};
    else if (command === "resolve-member") result = await client.resolveMember(await input());
    else if (command === "resolve-copy") result = await client.resolveCopy(await input());
    else if (command === "retry") result = {accepted_by_ilms: true, loan: await client.retry(argument)};
    else { client.discard(argument); result = {removed_locally: true, cancelled_in_ilms: false}; }
    process.stdout.write(JSON.stringify(result) + "\n");
  } finally { journal.close(); }
}
main().catch(error => {
  const safe = error instanceof IlmsClientError ? error : new IlmsClientError("storage");
  process.stderr.write(JSON.stringify({error: safe.code, status: safe.status, message: safe.message}) + "\n"); process.exitCode = 1;
});
