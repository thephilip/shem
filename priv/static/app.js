function shem() {
  return {
    // chat state
    preset: 'general',
    presets: [],              // [{name, description, deletable}]
    messages: [],
    inputText: '',
    status: 'idle',
    errorMsg: '',
    agentId: null,
    pendingContent: '',

    // shadow agent state
    shadowBand: null,
    shadowReasoning: '',
    showShadowPopover: false,
    _shadowPollTimer: null,

    // preset modal state
    showPresetModal: false,
    newPresetName: '',
    newPresetPrompt: '',
    createError: '',
    creating: false,

    async init() {
      await this._loadPresets();
      const params = new URLSearchParams(window.location.search);
      const resumeId = params.get('resume');
      if (resumeId) {
        await this._resumeSession(resumeId);
        window.history.replaceState({}, '', '/');
      }
    },

    async _resumeSession(sessionId) {
      this.messages.push({ role: 'assistant', content: '', pending: true });
      this.status = 'running';
      try {
        const res = await fetch('/api/agents', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ resume_session_id: sessionId })
        });
        if (!res.ok) {
          this.errorMsg = 'Failed to resume session';
          this.status = 'error';
          this.messages[this.messages.length - 1].pending = false;
          return;
        }
        const data = await res.json();
        this.agentId = data.agent_id;
        this._startShadowPolling();
        await this._openStream(this.agentId);
      } catch (_) {
        this.errorMsg = 'Failed to resume session';
        this.status = 'error';
        this.messages[this.messages.length - 1].pending = false;
      }
    },

    async _loadPresets() {
      try {
        const res = await fetch('/api/presets');
        if (!res.ok) throw new Error();
        this.presets = await res.json();
        // ensure current preset is still valid
        if (!this.presets.find(p => p.name === this.preset)) {
          this.preset = 'general';
        }
      } catch (_) {
        // fallback so the UI is never broken
        this.presets = [{ name: 'general', description: 'General assistant.', deletable: false }];
      }
    },

    openPresetModal() {
      this.newPresetName = '';
      this.newPresetPrompt = '';
      this.createError = '';
      this.creating = false;
      this.showPresetModal = true;
    },

    closePresetModal() {
      this.showPresetModal = false;
    },

    _startShadowPolling() {
      this._stopShadowPolling();
      this._shadowPollTimer = setInterval(async () => {
        if (!this.agentId) return;
        try {
          const res = await fetch(`/api/agents/${this.agentId}/shadow`);
          if (!res.ok) return;
          const data = await res.json();
          this.shadowBand = data.band ?? null;
          this.shadowReasoning = data.reasoning ?? '';
        } catch (_) {}
      }, 3000);
    },

    _stopShadowPolling() {
      if (this._shadowPollTimer) {
        clearInterval(this._shadowPollTimer);
        this._shadowPollTimer = null;
      }
    },

    async createPreset() {
      const name   = this.newPresetName.trim();
      const prompt = this.newPresetPrompt.trim();
      if (!name || !prompt) {
        this.createError = 'Name and system prompt are required.';
        return;
      }
      this.creating = true;
      this.createError = '';
      try {
        const res = await fetch('/api/presets', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name, system_prompt: prompt })
        });
        const data = await res.json();
        if (!res.ok) {
          this.createError = data.error || 'Failed to create preset.';
          return;
        }
        this.presets.push(data);
        this.preset = data.name;
        this.newPresetName = '';
        this.newPresetPrompt = '';
      } catch (_) {
        this.createError = 'Network error.';
      } finally {
        this.creating = false;
      }
    },

    async deletePreset(name) {
      try {
        const res = await fetch(`/api/presets/${encodeURIComponent(name)}`, { method: 'DELETE' });
        if (!res.ok) return;
        this.presets = this.presets.filter(p => p.name !== name);
        if (this.preset === name) this.preset = 'general';
      } catch (_) {}
    },

    async send() {
      const text = this.inputText.trim();
      if (!text || this.status === 'running') return;
      this.inputText = '';
      this.errorMsg = '';

      if (this.status === 'idle') {
        await this._startAgent(text);
      } else if (this.status === 'waiting') {
        await this._sendMessage(text);
      }
    },

    async _startAgent(text) {
      this.messages.push({ role: 'user', content: text, pending: false });
      this.messages.push({ role: 'assistant', content: '', pending: true });
      this.status = 'running';

      try {
        const res = await fetch('/api/agents', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ preset: this.preset, task: text, conversational: true })
        });
        if (!res.ok) throw new Error('Failed to start agent');
        const data = await res.json();
        this.agentId = data.agent_id;
        this._startShadowPolling();
        await this._openStream(this.agentId);
      } catch (e) {
        this.errorMsg = e.message;
        this.status = 'error';
        this.messages[this.messages.length - 1].pending = false;
      }
    },

    async _sendMessage(text) {
      this.messages.push({ role: 'user', content: text, pending: false });
      this.messages.push({ role: 'assistant', content: '', pending: true });
      this.status = 'running';

      try {
        const res = await fetch(`/api/agents/${this.agentId}/message`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: text })
        });
        if (!res.ok) throw new Error('Failed to send message');
        await this._openStream(this.agentId);
      } catch (e) {
        this.errorMsg = e.message;
        this.status = 'error';
        this.messages[this.messages.length - 1].pending = false;
      }
    },

    async _openStream(agentId) {
      this.pendingContent = '';
      const es = new EventSource(`/api/agents/${agentId}/stream`);

      es.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        if (msg.type === 'chunk') {
          this.pendingContent += msg.content;
          const last = this.messages[this.messages.length - 1];
          if (last && last.pending) last.content = this.pendingContent;
          this.$nextTick(() => {
            const el = this.$refs.chatBody;
            if (el) el.scrollTop = el.scrollHeight;
          });
        } else if (msg.type === 'done') {
          es.close();
          const last = this.messages[this.messages.length - 1];
          if (last) last.pending = false;
          this.status = msg.status === 'error' ? 'error' : 'waiting';
          this.pendingContent = '';
        }
      };

      es.onerror = () => {
        es.close();
        const last = this.messages[this.messages.length - 1];
        if (last) last.pending = false;
        if (this.status === 'running') {
          this.status = 'error';
          this.errorMsg = 'Connection lost.';
        }
      };
    },

    newChat() {
      this._stopShadowPolling();
      this.messages = [];
      this.agentId = null;
      this.status = 'idle';
      this.inputText = '';
      this.errorMsg = '';
      this.pendingContent = '';
      this.shadowBand = null;
      this.shadowReasoning = '';
      this.showShadowPopover = false;
    }
  };
}

// ── Timeline: Alpine components (registered on alpine:init so Alpine exists) ──

document.addEventListener('alpine:init', () => {

// ── Timeline: Session List ───────────────────────────────────────────────────

Alpine.data('sessionList', () => ({
  sessions: [],
  selectedId: null,
  showAll: false,
  _pollTimer: null,

  async init() {
    await this.load();
    this._pollTimer = setInterval(() => this.load(), 5000);
  },

  destroy() {
    clearInterval(this._pollTimer);
  },

  async load() {
    try {
      const res = await fetch('/api/sessions');
      if (res.ok) this.sessions = await res.json();
    } catch (_) {}
  },

  // A "husk" is an ended session with nothing to inspect: no task and no turns.
  // These accumulate from partial/test runs; an instrument shouldn't lead with noise,
  // but they stay one click away (showAll) rather than being silently dropped.
  isHusk(s) {
    return !s.active && !s.task && (s.turn_count || 0) === 0;
  },

  visibleSessions() {
    return this.showAll ? this.sessions : this.sessions.filter((s) => !this.isHusk(s));
  },

  huskCount() {
    return this.sessions.filter((s) => this.isHusk(s)).length;
  },

  select(sessionId) {
    this.selectedId = sessionId;
    window.dispatchEvent(new CustomEvent('session-selected', { detail: { sessionId } }));
  },

  borderColor(s) {
    if (s.session_id === this.selectedId) return 'var(--accent)';
    if (s.active) return 'var(--ok)';
    return 'transparent';
  },

  statusLabel(s) {
    const map = { running: '● LIVE', done: '✓ DONE', error: '✕ ERROR', fork: '⑂ FORK', unknown: '? UNKNOWN' };
    return map[s.status] || s.status.toUpperCase();
  },

  statusColor(status) {
    const map = { running: 'var(--ok)', done: 'var(--ink-2)', error: 'var(--bad)', fork: 'var(--accent)', unknown: 'var(--ink-3)' };
    return map[status] || 'var(--ink-3)';
  },

  timeAgo(isoStr) {
    if (!isoStr) return '—';
    const diff = Math.floor((Date.now() - new Date(isoStr)) / 1000);
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return `${Math.floor(diff / 86400)}d ago`;
  },

  truncate(str, max) {
    if (!str) return '(no task)';
    return str.length <= max ? str : str.slice(0, max) + '…';
  }
}));

// ── Timeline: Event Timeline ─────────────────────────────────────────────────

Alpine.data('eventTimeline', () => ({
  sessionId: null,
  events: [],
  expanded: {},
  loading: false,
  asOf: 0,           // scrub position: index of the "as-of" event (playhead)
  verify: null,      // hash-chain verify state: {state, events?, brokenAt?}

  init() {
    window.addEventListener('session-selected', (e) => {
      this.exitCompare();
      this.sessionId = e.detail.sessionId;
      this.load();
    });
    window.addEventListener('fork-created', (e) => {
      if (e.detail.originId === this.sessionId) this.showCompare(e.detail.originId, e.detail.sessionId);
    });
  },

  async load() {
    if (!this.sessionId) return;
    this.loading = true;
    this.expanded = {};
    let evs = [];
    try {
      const res = await fetch(`/api/sessions/${this.sessionId}/events`);
      if (res.ok) evs = await res.json();
    } catch (_) {}
    // A fork carries a branch_created marker — open it compared to its parent.
    const branch = evs.find((e) => e.type === 'branch_created');
    if (branch && branch.payload && branch.payload.original_session_id) {
      this.loading = false;
      return this.showCompare(branch.payload.original_session_id, this.sessionId);
    }
    this.events = evs;
    this.asOf = Math.max(0, this.events.length - 1);  // default playhead = latest
    this.loading = false;
    this.loadVerify();
  },

  // ── Hash-chain verify ───────────────────────────────────────────────────
  verifyOrig: null,
  verifyFork: null,

  async fetchVerify(sessionId) {
    try {
      const res = await fetch(`/api/sessions/${sessionId}/verify`);
      if (!res.ok) return { state: 'error' };
      const b = await res.json();
      if (b.verified === true) return { state: 'verified', events: b.events };
      if (b.verified === 'legacy') return { state: 'legacy', events: b.events };
      if (b.verified === false) return { state: 'tampered', brokenAt: b.broken_at };
      return { state: 'error' };
    } catch (_) { return { state: 'error' }; }
  },

  async loadVerify() {
    this.verify = { state: 'loading' };
    this.verify = await this.fetchVerify(this.sessionId);
  },

  verifyBadgeOf(v) {
    if (!v) return null;
    switch (v.state) {
      case 'loading':  return { glyph: '◌', text: 'verifying…', cls: 'v-loading' };
      case 'verified': return { glyph: '✓', text: `verified · ${v.events} events`, cls: 'v-ok' };
      case 'legacy':   return { glyph: '▲', text: 'legacy · unverifiable', cls: 'v-warn' };
      case 'tampered': return { glyph: '✕', text: `tampered at ${(v.brokenAt || '').slice(0, 12)}…`, cls: 'v-bad' };
      default:         return { glyph: '?', text: 'verify unavailable', cls: 'v-warn' };
    }
  },
  verifyBadge()     { return this.verifyBadgeOf(this.verify); },
  verifyBadgeOrig() { return this.verifyBadgeOf(this.verifyOrig); },
  verifyBadgeFork() { return this.verifyBadgeOf(this.verifyFork); },

  // ── Scrub transport ─────────────────────────────────────────────────────
  isFuture(i)  { return i > this.asOf; },
  tickPct(i)   { return this.events.length <= 1 ? 0 : (i / (this.events.length - 1)) * 100; },
  playheadTime() {
    const e = this.events[this.asOf];
    return e ? this.formatTime(e.timestamp) : '';
  },

  // ── Compare: side-by-side original vs fork ──────────────────────────────
  comparing: false,
  compareId: null,
  compareEvents: [],
  forkIdx: 0,        // index where the fork diverges (its last event)
  forkLive: false,   // is the compared fork a live continuation?
  forkStatus: null,  // 'running' | 'awaiting_turn' | 'done' | 'error' | 'fork' | ...
  _pollTimer: null,

  async showCompare(originalId, forkId) {
    this.stopPoll();
    let orig = [], fork = [];
    try { const r = await fetch(`/api/sessions/${originalId}/events`); if (r.ok) orig = await r.json(); } catch (_) {}
    try { const r = await fetch(`/api/sessions/${forkId}/events`); if (r.ok) fork = await r.json(); } catch (_) {}
    this.sessionId = originalId;
    this.events = orig;
    this.asOf = Math.max(0, orig.length - 1);
    this.compareEvents = fork.filter((e) => e.type !== 'branch_created');
    this.compareId = forkId;
    this.forkIdx = this.computeForkIdx(this.events, this.compareEvents);
    this.verifyOrig = await this.fetchVerify(originalId);
    this.verifyFork = await this.fetchVerify(forkId);
    this.verify = this.verifyOrig;
    this.forkStatus = await this.fetchStatus(forkId);
    // A fork is "live" while its session is still active (running / awaiting a turn).
    this.forkLive = this.forkStatus === 'running' || this.forkStatus === 'awaiting_turn';
    this.comparing = true;
    if (this.forkLive) this.startPoll(forkId);
  },

  exitCompare() {
    this.stopPoll();
    this.comparing = false; this.compareEvents = []; this.compareId = null;
    this.verifyOrig = null; this.verifyFork = null;
    this.forkLive = false; this.forkStatus = null;
  },

  async fetchStatus(sessionId) {
    try {
      const r = await fetch('/api/sessions');
      if (!r.ok) return null;
      const s = (await r.json()).find((x) => x.session_id === sessionId);
      return s ? s.status : null;
    } catch (_) { return null; }
  },

  startPoll(forkId) {
    this._pollTimer = setInterval(async () => {
      this.forkStatus = (await this.fetchStatus(forkId)) || this.forkStatus;
      // grow the fork lane
      try {
        const r = await fetch(`/api/sessions/${forkId}/events`);
        if (r.ok) {
          this.compareEvents = (await r.json()).filter((e) => e.type !== 'branch_created');
          this.forkIdx = this.computeForkIdx(this.events, this.compareEvents);
        }
      } catch (_) {}
      this.fetchVerify(forkId).then((v) => { this.verifyFork = v; });
      if (this.forkStatus === 'done' || this.forkStatus === 'error') {
        this.forkLive = false;
        this.stopPoll();
      }
    }, 2000);
  },

  stopPoll() {
    if (this._pollTimer) { clearInterval(this._pollTimer); this._pollTimer = null; }
  },

  forkStatusLabel() {
    const map = { running: '● running', awaiting_turn: '● awaiting turn', done: '✓ done', error: '✕ error' };
    return this.forkStatus ? (map[this.forkStatus] || this.forkStatus) : '';
  },

  computeForkIdx(orig, fork) {
    const n = Math.min(orig.length, fork.length);
    for (let i = 0; i < n; i++) {
      const a = orig[i], b = fork[i];
      if (a.type !== b.type) return i;
      if (a.type === 'llm_call_completed' && ((a.payload || {}).content || '') !== ((b.payload || {}).content || '')) return i;
    }
    return n;
  },

  // i < forkIdx: shared (identical prefix). i >= forkIdx: diverged — each lane
  // shows its own path (original's recorded continuation / fork's live one).
  shared(i)   { return i < this.forkIdx; },
  diverged(i) { return i >= this.forkIdx; },
  isForkPoint(i) { return i === this.forkIdx; },   // the edited answer (first diverged fork row)

  toggle(id) {
    this.expanded[id] = !this.expanded[id];
    this.expanded = { ...this.expanded };
  },

  isExpanded(id) {
    return !!this.expanded[id];
  },

  openFork(event) {
    const i = this.events.indexOf(event);
    window.dispatchEvent(new CustomEvent('fork-requested', {
      detail: { event, sessionId: this.sessionId, prompt: this.promptFor(i) }
    }));
  },

  // The prompt lives on the preceding llm_call_started, not on the completed
  // event (which only carries content/tokens/latency). Walk back to find it.
  promptFor(i) {
    for (let j = i - 1; j >= 0; j--) {
      const e = this.events[j];
      if (e.type === 'llm_call_started') {
        const p = (e.payload || {}).prompt;
        if (!p) return '—';
        return typeof p === 'string' ? p : this.prettyJson(p);
      }
      if (e.type === 'llm_call_completed') break; // don't cross into an earlier call
    }
    return '—';
  },

  dotColor(type) {
    const map = {
      llm_call_completed: 'var(--ev-llm)',
      llm_call_started:   'var(--ev-llm-dim)',
      tool_call:          'var(--ev-tool)',
      agent_tool_called:  'var(--ev-tool)',
      agent_tool_result:  'var(--ev-tool-dim)',
      agent_thinking:     'var(--ev-think)',
      agent_done:         'var(--ev-grad)',
      agent_error:        'var(--ev-error)',
      error:              'var(--ev-error)',
      branch_created:     'var(--accent)',
    };
    return map[type] || 'var(--ev-system)';
  },

  // Colorblind-safe second channel: every semantic color is paired with a glyph
  // (and the text label), so the encoding survives deuteranopia/protanopia.
  glyph(type) {
    const map = {
      llm_call_completed: '◇',
      llm_call_started:   '◇',
      tool_call:          '▸',
      agent_tool_called:  '▸',
      agent_tool_result:  '◂',
      agent_thinking:     '∿',
      agent_done:         '✓',
      agent_error:        '✕',
      error:              '✕',
      branch_created:     '⑂',
      agent_started:      '▸',
    };
    return map[type] || '·';
  },

  label(event) {
    const p = event.payload || {};
    switch (event.type) {
      case 'agent_started':        return `Agent started${p.preset ? ' · ' + p.preset : ''}`;
      case 'agent_checkpoint':     return 'Checkpoint';
      case 'agent_turn_started':   return `Turn ${p.turn || ''} started`.trim();
      case 'llm_call_started':     return `LLM call started${p.model ? ' → ' + p.model : ''}`;
      case 'llm_call_completed': {
        const lat = p.latency_ms ? `${(p.latency_ms / 1000).toFixed(1)}s` : '';
        const tok = p.tokens_used ? `${p.tokens_used} tok` : '';
        return ['LLM call', lat, tok].filter(Boolean).join(' · ');
      }
      case 'tool_call':            return `Tool: ${p.name || p.tool || ''}`;
      case 'agent_tool_called':    return `Tool: ${p.tool || ''} · ${JSON.stringify(p.args || {}).slice(0, 40)}`;
      case 'agent_tool_result':    return `Tool result: ${p.tool || ''}`;
      case 'agent_turn_completed': return `Turn ${p.turn || ''} complete`;
      case 'agent_done':           return 'Done';
      case 'agent_error':          return `Error: ${p.message || p.reason || ''}`;
      case 'branch_created':       return `Branched from ${(p.original_session_id || '').slice(0, 12)}…`;
      default:                     return event.type;
    }
  },

  canFork(type)   { return type === 'llm_call_completed'; },

  // Only events that actually carry inspectable detail are expandable — no fake
  // expand-arrows on empty rows.
  canExpand(type) {
    return ['llm_call_completed','tool_call','agent_tool_called','agent_tool_result',
            'agent_thinking','agent_error','error'].includes(type);
  },

  // Bookkeeping events: real, but noise relative to the work. Render compact + dim
  // so the signal (LLM calls, thinking, tool calls, errors) stands out.
  isMinor(type) {
    return ['agent_started','agent_checkpoint','agent_turn_started',
            'agent_turn_completed','llm_call_started'].includes(type);
  },

  formatTime(iso) {
    if (!iso) return '';
    return new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  },

  prettyJson(obj) {
    try { return JSON.stringify(obj, null, 2); } catch (_) { return String(obj); }
  },

  // Render a payload as key/value rows. String values are shown raw (real
  // newlines via pre-wrap) instead of JSON-escaped — pytest output, errors,
  // and multi-line content stay readable. Nested objects fall back to JSON.
  payloadEntries(payload) {
    return (payload && typeof payload === 'object') ? Object.entries(payload) : [];
  },
  payloadVal(v) {
    return typeof v === 'string' ? v : this.prettyJson(v);
  }
}));

// ── Timeline: Fork Modal ─────────────────────────────────────────────────────

Alpine.data('forkModal', () => ({
  open: false,
  sessionId: null,
  event: null,
  prompt: '',
  altResponse: '',
  forking: false,
  success: false,
  error: '',

  init() {
    window.addEventListener('fork-requested', (e) => {
      this.sessionId = e.detail.sessionId;
      this.event = e.detail.event;
      this.prompt = e.detail.prompt || '';
      this.altResponse = (e.detail.event.payload || {}).content || '';
      this.forking = false;
      this.success = false;
      this.error = '';
      this.open = true;
    });
  },

  close() { this.open = false; },

  async fork(continue_) {
    this.forking = continue_ ? 'continue' : 'compare';
    this.error = '';
    try {
      const res = await fetch(`/api/sessions/${this.sessionId}/fork`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fork_event_id: this.event.id, alt_response: this.altResponse, continue: continue_ })
      });
      const body = await res.json();
      if (!res.ok) {
        this.error = body.error || 'Fork failed';
        this.forking = false;
        return;
      }
      this.success = true;
      const newId = body.session_id, originId = this.sessionId;
      setTimeout(() => {
        // Liveness is auto-detected in showCompare from the fork's status, so the
        // event only carries the ids (works for fresh forks AND later re-opens).
        window.dispatchEvent(new CustomEvent('fork-created', { detail: { sessionId: newId, originId } }));
        this.close();
      }, 600);
    } catch (_) {
      this.error = 'Network error';
      this.forking = false;
    }
  },

  promptSnippet() {
    const p = this.prompt || '';
    return p.length > 200 ? p.slice(0, 200) + '…' : p;
  }
}));

}); // end alpine:init
