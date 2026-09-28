import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";
import path from "node:path";
import readline from "node:readline";

export class ReaderService extends EventEmitter {
  constructor(executable, marker) {
    super();
    this.executable = executable;
    this.marker = marker;
    this.process = null;
    this.pending = new Map();
    this.nextId = 1;
    this.readyPromise = null;
    this.connection = null;
    this.connected = false;
  }

  async start() {
    if (this.process && !this.process.killed) return this.readyPromise;
    this.readyPromise = new Promise((resolve, reject) => {
      const child = spawn(this.executable, ["daemon"], {
        cwd: path.dirname(this.executable),
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"]
      });
      this.process = child;
      const lines = readline.createInterface({ input: child.stdout });
      lines.on("line", (line) => this.handleLine(line, resolve));
      child.stderr.on("data", (chunk) => this.emit("diagnostic", chunk.toString()));
      child.once("error", reject);
      child.once("exit", (code) => {
        this.connected = false;
        this.connection = null;
        this.process = null;
        for (const { reject: rejectPending, timer } of this.pending.values()) {
          clearTimeout(timer);
          rejectPending(new Error(`Le pont RFID s'est arrêté (code ${code ?? "inconnu"}).`));
        }
        this.pending.clear();
        this.emit("disconnected");
      });
    });
    return this.readyPromise;
  }

  handleLine(line, ready) {
    if (!line.startsWith(this.marker)) return;
    try {
      const message = JSON.parse(line.slice(this.marker.length));
      if (message.type === "ready") {
        ready(message);
        return;
      }
      if (message.type === "tag") {
        this.emit("tag", message.tag);
        return;
      }
      if (message.type === "response") {
        const pending = this.pending.get(Number(message.id));
        if (!pending) return;
        clearTimeout(pending.timer);
        this.pending.delete(Number(message.id));
        if (message.ok) pending.resolve(message);
        else pending.reject(new Error(message.error || "Commande RFID refusée."));
      }
    } catch (error) {
      this.emit("diagnostic", `Réponse RFID invalide: ${error.message}`);
    }
  }

  async command(action, payload = {}, timeout = 12000) {
    await this.start();
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Le lecteur n'a pas répondu à la commande ${action}.`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.process.stdin.write(`${JSON.stringify({ id, action, ...payload })}\n`, (error) => {
        if (!error) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error);
      });
    });
  }

  async connect(connection) {
    const key = `${connection.type}:${connection.endpoint || ""}`;
    const currentKey = this.connection ? `${this.connection.type}:${this.connection.endpoint || ""}` : "";
    if (this.connected && key === currentKey) return { ok: true, connected: true, reused: true };
    if (this.connected) await this.disconnect();
    const result = await this.command("connect", {
      connectionType: connection.type,
      endpoint: connection.endpoint || ""
    });
    this.connection = { ...connection };
    this.connected = true;
    this.emit("connected", result);
    return result;
  }

  async disconnect() {
    if (!this.process || !this.connected) return;
    try { await this.command("disconnect", {}, 5000); }
    finally {
      this.connected = false;
      this.connection = null;
    }
  }

  async beep() {
    if (!this.connected) return { ok: false, beeped: false };
    return this.command("beep", {}, 4000);
  }

  async write(epc, tid) {
    if (!this.connected) throw new Error("Le lecteur RFID n'est pas connecté.");
    return this.command("write", { epc, tid }, 12000);
  }

  async shutdown() {
    if (!this.process) return;
    const child = this.process;
    const exited = new Promise((resolve) => child.once("exit", resolve));
    try { await this.command("shutdown", {}, 3000); }
    catch { child.kill(); }
    await Promise.race([
      exited,
      new Promise((resolve) => setTimeout(resolve, 2000))
    ]);
    if (this.process === child) {
      child.kill();
      await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 1000))]);
    }
  }
}
