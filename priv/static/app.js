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

  select(sessionId) {
    this.selectedId = sessionId;
    window.dispatchEvent(new CustomEvent('session-selected', { detail: { sessionId } }));
  },

  borderColor(s) {
    if (s.session_id === this.selectedId) return '#60a5fa';
    if (s.active) return '#4ade80';
    return 'transparent';
  },

  statusLabel(s) {
    const map = { running: '● LIVE', done: '✓ DONE', error: '✗ ERROR', unknown: '? UNKNOWN' };
    return map[s.status] || s.status.toUpperCase();
  },

  statusColor(status) {
    const map = { running: '#4ade80', done: '#60a5fa', error: '#f87171', unknown: '#666' };
    return map[status] || '#666';
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

  init() {
    window.addEventListener('session-selected', (e) => {
      this.sessionId = e.detail.sessionId;
      this.load();
    });
  },

  async load() {
    if (!this.sessionId) return;
    this.loading = true;
    this.expanded = {};
    try {
      const res = await fetch(`/api/sessions/${this.sessionId}/events`);
      if (res.ok) this.events = await res.json();
    } catch (_) {}
    this.loading = false;
  },

  toggle(id) {
    this.expanded[id] = !this.expanded[id];
    this.expanded = { ...this.expanded };
  },

  isExpanded(id) {
    return !!this.expanded[id];
  },

  openFork(event) {
    window.dispatchEvent(new CustomEvent('fork-requested', {
      detail: { event, sessionId: this.sessionId }
    }));
  },

  dotColor(type) {
    const map = {
      llm_call_completed: '#818cf8',
      llm_call_started:   '#4c4f8f',
      tool_call:          '#f59e0b',
      agent_tool_called:  '#f59e0b',
      agent_tool_result:  '#d97706',
      agent_done:         '#4ade80',
      agent_error:        '#f87171',
      branch_created:     '#60a5fa',
    };
    return map[type] || '#6b7280';
  },

  label(event) {
    const p = event.payload || {};
    switch (event.type) {
      case 'agent_started':        return `Agent started · ${p.preset || ''}`;
      case 'llm_call_started':     return `LLM call → ${p.model || ''}`;
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

  canExpand(type) {
    return ['llm_call_completed','tool_call','agent_tool_called','agent_tool_result','agent_done','agent_error'].includes(type)
      || !['agent_started','llm_call_started','agent_turn_completed','branch_created'].includes(type);
  },

  formatTime(iso) {
    if (!iso) return '';
    return new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  },

  prettyJson(obj) {
    try { return JSON.stringify(obj, null, 2); } catch (_) { return String(obj); }
  }
}));

// ── Timeline: Fork Modal ─────────────────────────────────────────────────────

Alpine.data('forkModal', () => ({
  open: false,
  sessionId: null,
  event: null,
  altResponse: '',
  forking: false,
  success: false,
  error: '',

  init() {
    window.addEventListener('fork-requested', (e) => {
      this.sessionId = e.detail.sessionId;
      this.event = e.detail.event;
      this.altResponse = (e.detail.event.payload || {}).content || '';
      this.forking = false;
      this.success = false;
      this.error = '';
      this.open = true;
    });
  },

  close() { this.open = false; },

  async fork() {
    this.forking = true;
    this.error = '';
    try {
      const res = await fetch(`/api/sessions/${this.sessionId}/fork`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fork_event_id: this.event.id, alt_response: this.altResponse })
      });
      const body = await res.json();
      if (!res.ok) {
        this.error = body.error || 'Fork failed';
        this.forking = false;
        return;
      }
      this.success = true;
      setTimeout(() => { window.location.href = `/?resume=${body.session_id}`; }, 800);
    } catch (_) {
      this.error = 'Network error';
      this.forking = false;
    }
  },

  promptSnippet() {
    const p = (this.event && this.event.payload) || {};
    const prompt = p.prompt || p.messages || '';
    return typeof prompt === 'string' ? prompt.slice(0, 200) : JSON.stringify(prompt).slice(0, 200);
  }
}));

}); // end alpine:init
