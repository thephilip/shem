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
