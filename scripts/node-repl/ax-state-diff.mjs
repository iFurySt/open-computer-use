// Deltas preserve every line, including indentation, focus, selection and notes.
function partition(text) {
  const elements = new Map(), layout = [], header = [];
  let foundElement = false;
  for (const line of text.split("\n")) {
    const match = /^[\t ]*(0|[1-9]\d*)(?=\s|$)/u.exec(line);
    if (!match) {
      layout.push(line);
      if (!foundElement) header.push(line);
      continue;
    }
    const index = Number(match[1]);
    if (!Number.isSafeInteger(index) || elements.has(index)) return null;
    foundElement = true;
    elements.set(index, line);
    layout.push(index);
  }
  return { elements, layout, identity: JSON.stringify(header) };
}

export class AXStateDiff {
  constructor() { this.revision = 0; this.reset(); }
  reset() { this.previous = null; this.scope = null; }

  observe(text, scope = "") {
    const current = partition(text);
    const revision = ++this.revision;
    const previous = this.previous;
    let packet;
    if (!current || !previous || scope !== this.scope || current.identity !== previous.identity) {
      packet = { type: "ax-full", revision, text };
    } else {
      const added = [], changed = [], removed = [];
      for (const [index, line] of current.elements) {
        if (!previous.elements.has(index)) added.push({ index, text: line });
        else if (previous.elements.get(index) !== line) changed.push({ index, text: line });
      }
      for (const index of previous.elements.keys()) {
        if (!current.elements.has(index)) removed.push(index);
      }
      packet = { type: "ax-diff", baseRevision: previous.revision, revision, added, changed, removed };
      if (JSON.stringify(current.layout) !== JSON.stringify(previous.layout)) packet.layout = current.layout;
    }
    this.previous = current ? { ...current, revision } : null;
    this.scope = scope;
    return JSON.stringify(packet);
  }
}

// Consumers must reject a gap rather than apply a delta to a stale baseline.
export function applyAXStateDiff(state, packet) {
  if (packet.type === "ax-full") return { revision: packet.revision, text: packet.text };
  if (packet.type !== "ax-diff" || !state || state.revision !== packet.baseRevision) {
    throw new Error("AX diff baseline mismatch; request a full snapshot");
  }
  const previous = partition(state.text);
  if (!previous) throw new Error("AX diff baseline has duplicate element indexes");
  const elements = previous.elements;
  for (const index of packet.removed) {
    if (!elements.delete(index)) throw new Error("AX diff removes an unknown index");
  }
  for (const { index, text } of packet.added) {
    if (elements.has(index)) throw new Error("AX diff adds an existing index");
    elements.set(index, text);
  }
  for (const { index, text } of packet.changed) {
    if (!elements.has(index)) throw new Error("AX diff changes an unknown index");
    elements.set(index, text);
  }
  const text = (packet.layout ?? previous.layout).map(item => {
    if (typeof item === "string") return item;
    if (!elements.has(item)) throw new Error("AX diff layout refers to an unknown index");
    return elements.get(item);
  }).join("\n");
  return { revision: packet.revision, text };
}
