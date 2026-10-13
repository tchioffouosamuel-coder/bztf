import { randomInt } from "node:crypto";

// Windows may allocate ephemeral ports that browsers and fetch refuse.
export async function listenForBrowser(server) {
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      await new Promise((resolve, reject) => {
        const failed = error => { server.removeListener("listening", ready); reject(error); };
        const ready = () => { server.removeListener("error", failed); resolve(); };
        server.once("error", failed); server.once("listening", ready);
        server.listen(randomInt(20000, 65536), "127.0.0.1");
      });
      return;
    } catch (error) {
      if (error.code !== "EADDRINUSE") throw error;
    }
  }
  throw new Error("Aucun port local de recette disponible.");
}
