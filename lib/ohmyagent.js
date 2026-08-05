'use strict';

const crypto = require('crypto');

const SIGNATURE_HEADER = 'X-OhMyAgent-Signature';

class OhMyAgentError extends Error {}

function decodeFirstPromptBlock(raw) {
  if (raw === undefined || raw === null) return { ok: false };
  if (typeof raw === 'string') {
    return raw !== '' ? { ok: true, text: raw } : { ok: false };
  }
  if (Array.isArray(raw)) {
    const first = raw[0];
    if (first !== undefined && first !== null && typeof first === 'object' && typeof first.text === 'string' && first.text !== '') {
      return { ok: true, text: first.text };
    }
    return { ok: false };
  }
  return { ok: false };
}

function decodePrompt(raw) {
  if (raw === undefined || raw === null) return { ok: false };
  if (typeof raw === 'string') {
    return raw !== '' ? { ok: true, text: raw } : { ok: false };
  }
  if (Array.isArray(raw)) {
    const texts = [];
    for (const part of raw) {
      if (part && typeof part === 'object' && typeof part.text === 'string' && part.text !== '') {
        texts.push(part.text);
      }
    }
    return texts.length > 0 ? { ok: true, text: texts.join('\n') } : { ok: false };
  }
  return { ok: false };
}

function extractSystemPrompt(body) {
  if (!body || typeof body !== 'object') {
    throw new OhMyAgentError('invalid request body');
  }

  const fromSystem = decodeFirstPromptBlock(body.system);
  if (fromSystem.ok) return fromSystem.text;

  const fromInstructions = decodePrompt(body.instructions);
  if (fromInstructions.ok) return fromInstructions.text;

  if (Array.isArray(body.messages)) {
    for (const message of body.messages) {
      if (message && message.role === 'system') {
        const fromContent = decodePrompt(message.content);
        if (fromContent.ok) return fromContent.text;
        break;
      }
    }
  }

  if (Array.isArray(body.input)) {
    for (const message of body.input) {
      if (message && (message.role === 'developer' || message.role === 'system')) {
        const fromContent = decodePrompt(message.content);
        if (fromContent.ok) return fromContent.text;
        break;
      }
    }
  }

  throw new OhMyAgentError('system prompt not found');
}

function computeSignature(signingSecret, prompt) {
  const mac = crypto.createHmac('sha256', signingSecret).update(prompt, 'utf8');
  return 'v1=' + mac.digest('hex');
}

function rewriteModel(body, modelName) {
  body.model = modelName;
  return body;
}

function verifySignature(signingSecret, signature, prompt) {
  if (!signingSecret) throw new OhMyAgentError('signing secret is empty');

  if (typeof signature !== 'string') throw new OhMyAgentError('unsupported signature');
  const trimmed = signature.trim();
  if (!trimmed.startsWith('v1=')) throw new OhMyAgentError('unsupported signature');
  const encoded = trimmed.slice(3);

  let provided;
  try {
    provided = Buffer.from(encoded, 'hex');
  } catch (err) {
    throw new OhMyAgentError('malformed signature');
  }
  if (provided.length !== crypto.createHash('sha256').digest().length) {
    throw new OhMyAgentError('malformed signature');
  }

  const expected = computeSignature(signingSecret, prompt).slice(3);
  const expectedBuf = Buffer.from(expected, 'hex');
  if (!crypto.timingSafeEqual(provided, expectedBuf)) {
    throw new OhMyAgentError('signature mismatch');
  }
  return true;
}

module.exports = {
  SIGNATURE_HEADER,
  OhMyAgentError,
  extractSystemPrompt,
  computeSignature,
  rewriteModel,
  verifySignature,
};
