/**
 * Routes HTTP du catalogage assisté. Montées par `server.js` derrière la même
 * session utilisateur que le reste de l'API.
 */
import { AiUnavailableError } from "./ai.js";
import { NoticeNotFoundError, NoticeNetworkError } from "./notice.js";
import { contentTypeFor, MAX_IMAGE_BYTES } from "./store.js";

const MAX_UPLOAD_BYTES = 14 * 1024 * 1024;

/** Corps JSON d'une capture : plus large que l'API courante (image en base64). */
async function readUploadBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_UPLOAD_BYTES)
      throw new Error("L’image envoyée est trop volumineuse.");
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new Error("Corps JSON invalide.");
  }
}

function decodeImage(value) {
  const text = String(value || "");
  const match = /^data:([^;]+);base64,(.*)$/s.exec(text);
  const base64 = match ? match[2] : text;
  const contentType = match ? match[1] : "";
  const buffer = Buffer.from(base64.replace(/\s+/g, ""), "base64");
  if (!buffer.length) throw new Error("Aucune image reçue.");
  if (buffer.length > MAX_IMAGE_BYTES) throw new Error("L’image dépasse 8 Mo.");
  return { buffer, contentType };
}

function statusFor(error) {
  if (error instanceof AiUnavailableError) return 409;
  if (error instanceof NoticeNotFoundError) return 404;
  if (error instanceof NoticeNetworkError) return 503;
  return 400;
}

export async function handleCataloguingRequest({
  request,
  response,
  url,
  db,
  service,
  json,
  readBody,
  user,
}) {
  const { pathname } = url;
  const { method } = request;
  if (!pathname.startsWith("/api/cataloguing")) return false;

  const fail = (error) =>
    json(response, statusFor(error), { error: error.message });

  if (method === "GET" && pathname === "/api/cataloguing/settings")
    return json(response, 200, service.settings());

  if (method === "PUT" && pathname === "/api/cataloguing/settings") {
    try {
      return json(response, 200, service.updateSettings(await readBody(request)));
    } catch (error) {
      return fail(error);
    }
  }

  if (method === "POST" && pathname === "/api/cataloguing/ai/test") {
    try {
      return json(response, 200, await service.ai.test());
    } catch (error) {
      return fail(error);
    }
  }

  if (method === "POST" && pathname === "/api/cataloguing/captures") {
    try {
      const input = await readUploadBody(request);
      const image = decodeImage(input.image);
      const thumb = input.thumb ? decodeImage(input.thumb) : null;
      const capture = service.addCapture({
        buffer: image.buffer,
        thumbBuffer: thumb?.buffer || null,
        contentType: input.contentType || image.contentType,
        kind: input.kind,
        source: input.source,
        itemId: input.itemId || null,
      });
      return json(response, 201, { capture: publicCapture(capture) });
    } catch (error) {
      return fail(error);
    }
  }

  const captureOcr = pathname.match(/^\/api\/cataloguing\/captures\/(\d+)\/ocr$/);
  if (captureOcr && method === "POST") {
    try {
      const result = await service.ocrCapture(captureOcr[1]);
      return json(response, 200, {
        capture: publicCapture(result.capture),
        text: result.text,
        engine: result.engine,
        confidence: result.confidence,
        durationMs: result.durationMs,
      });
    } catch (error) {
      return fail(error);
    }
  }

  const captureImage = pathname.match(
    /^\/api\/cataloguing\/captures\/(\d+)\/image$/,
  );
  if (captureImage && method === "GET") {
    const image = service.captureImage(captureImage[1], {
      thumb: url.searchParams.get("thumb") === "1",
    });
    if (!image) return json(response, 404, { error: "Image introuvable." });
    response.writeHead(200, {
      "Content-Type": contentTypeFor(image.relativePath),
      "Content-Length": image.buffer.length,
      "Cache-Control": "private, max-age=86400",
    });
    response.end(image.buffer);
    return true;
  }

  const captureDelete = pathname.match(/^\/api\/cataloguing\/captures\/(\d+)$/);
  if (captureDelete && method === "DELETE") {
    const removed = service.removeCapture(captureDelete[1]);
    return json(response, removed ? 200 : 404, {
      ok: removed,
      ...(removed ? {} : { error: "Capture introuvable." }),
    });
  }

  if (method === "POST" && pathname === "/api/cataloguing/identify") {
    try {
      const input = await readBody(request);
      const captures = (input.captureIds || [])
        .map((id) => db.getCapture(id))
        .filter(Boolean);
      const result = await service.identify({
        captures,
        isbn: input.isbn || "",
        title: input.title || "",
        author: input.author || "",
      });
      return json(response, 200, result);
    } catch (error) {
      return fail(error);
    }
  }

  if (method === "POST" && pathname === "/api/cataloguing/search") {
    try {
      const input = await readBody(request);
      return json(response, 200, await service.search(input));
    } catch (error) {
      return fail(error);
    }
  }

  if (method === "POST" && pathname === "/api/cataloguing/ai/complete") {
    try {
      const input = await readBody(request);
      return json(
        response,
        200,
        await service.ai.complete({
          fields: input.fields || {},
          prefixes: service.cotePrefixes(),
        }),
      );
    } catch (error) {
      return fail(error);
    }
  }

  if (method === "POST" && pathname === "/api/cataloguing/ai/review") {
    try {
      const input = await readBody(request);
      return json(response, 200, await service.ai.quality({ fields: input.fields || {} }));
    } catch (error) {
      return fail(error);
    }
  }

  if (method === "POST" && pathname === "/api/cataloguing/commit") {
    try {
      const input = await readBody(request);
      const book = service.commit({
        fields: input.fields || {},
        captureIds: input.captureIds || [],
        draft: Boolean(input.draft),
      });
      return json(response, 201, { book, covers: service.coversFor(book.id) });
    } catch (error) {
      return fail(error);
    }
  }

  const bookCovers = pathname.match(
    /^\/api\/cataloguing\/books\/(\d+)\/covers$/,
  );
  if (bookCovers && method === "GET")
    return json(response, 200, { covers: service.coversFor(bookCovers[1]) });

  // --- Catalogage en lot ---------------------------------------------------

  if (method === "GET" && pathname === "/api/cataloguing/sessions")
    return json(response, 200, { sessions: db.listCatalogSessions() });

  if (method === "POST" && pathname === "/api/cataloguing/sessions") {
    const input = await readBody(request);
    const session = db.createCatalogSession({
      label: input.label || "",
      userId: user?.id || null,
    });
    return json(response, 201, { session });
  }

  const sessionMatch = pathname.match(/^\/api\/cataloguing\/sessions\/(\d+)$/);
  if (sessionMatch && method === "GET") {
    const session = db.getCatalogSession(sessionMatch[1]);
    if (!session) return json(response, 404, { error: "Lot introuvable." });
    return json(response, 200, { session });
  }
  if (sessionMatch && method === "DELETE") {
    const session = db.getCatalogSession(sessionMatch[1]);
    if (!session) return json(response, 404, { error: "Lot introuvable." });
    // Les photos des livres non enregistrés n'ont plus de raison d'être.
    for (const item of session.items)
      for (const capture of item.captures)
        if (!capture.book_id) service.removeCapture(capture.id);
    db.deleteCatalogSession(session.id);
    return json(response, 200, { ok: true });
  }

  const sessionClose = pathname.match(
    /^\/api\/cataloguing\/sessions\/(\d+)\/close$/,
  );
  if (sessionClose && method === "POST")
    return json(response, 200, { session: db.closeCatalogSession(sessionClose[1]) });

  const sessionItems = pathname.match(
    /^\/api\/cataloguing\/sessions\/(\d+)\/items$/,
  );
  if (sessionItems && method === "POST") {
    const session = db.getCatalogSession(sessionItems[1]);
    if (!session) return json(response, 404, { error: "Lot introuvable." });
    return json(response, 201, { item: db.createCatalogItem(session.id) });
  }

  const sessionProcess = pathname.match(
    /^\/api\/cataloguing\/sessions\/(\d+)\/process$/,
  );
  if (sessionProcess && method === "POST") {
    const session = db.getCatalogSession(sessionProcess[1]);
    if (!session) return json(response, 404, { error: "Lot introuvable." });
    // Séquentiel : l'OCR est gourmand et la station RFID doit rester vive.
    for (const item of session.items) {
      if (["enregistre", "ignore", "pret"].includes(item.status)) continue;
      try {
        await service.processItem(item.id);
      } catch (error) {
        db.updateCatalogItem(item.id, { status: "echec", message: error.message });
      }
    }
    return json(response, 200, { session: db.getCatalogSession(session.id) });
  }

  const sessionCommit = pathname.match(
    /^\/api\/cataloguing\/sessions\/(\d+)\/commit$/,
  );
  if (sessionCommit && method === "POST") {
    try {
      return json(response, 200, service.commitSession(sessionCommit[1]));
    } catch (error) {
      return fail(error);
    }
  }

  const itemProcess = pathname.match(/^\/api\/cataloguing\/items\/(\d+)\/process$/);
  if (itemProcess && method === "POST") {
    try {
      return json(response, 200, { item: await service.processItem(itemProcess[1]) });
    } catch (error) {
      return fail(error);
    }
  }

  const itemMatch = pathname.match(/^\/api\/cataloguing\/items\/(\d+)$/);
  if (itemMatch && method === "PUT") {
    const input = await readBody(request);
    const patch = {};
    if (input.fields) patch.fields = input.fields;
    if (input.status) patch.status = input.status;
    if ("message" in input) patch.message = input.message;
    const item = db.updateCatalogItem(itemMatch[1], patch);
    if (!item) return json(response, 404, { error: "Livre du lot introuvable." });
    return json(response, 200, { item });
  }
  if (itemMatch && method === "DELETE") {
    const item = db.getCatalogItem(itemMatch[1]);
    if (!item) return json(response, 404, { error: "Livre du lot introuvable." });
    for (const capture of item.captures)
      if (!capture.book_id) service.removeCapture(capture.id);
    db.deleteCatalogItem(item.id);
    return json(response, 200, { ok: true });
  }

  return json(response, 404, { error: "Route de catalogage inconnue." });
}

function publicCapture(capture) {
  return {
    id: capture.id,
    kind: capture.kind,
    bytes: capture.bytes,
    source: capture.source,
    ocrText: capture.ocr_text,
    ocrEngine: capture.ocr_engine,
    ocrConfidence: capture.ocr_confidence,
    url: `/api/cataloguing/captures/${capture.id}/image`,
    thumbUrl: capture.thumb_path
      ? `/api/cataloguing/captures/${capture.id}/image?thumb=1`
      : `/api/cataloguing/captures/${capture.id}/image`,
  };
}
