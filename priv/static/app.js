function shem() {
  return {
    preset: 'general',
    presets: ['general', 'coder', 'researcher', 'writer', 'security', 'explorer'],
    messages: [],          // [{role: 'user'|'assistant', content: '', pending: bool}]
    inputText: '',
    status: 'idle',        // idle | running | waiting | error
    errorMsg: '',
    agentId: null,
    pendingContent: '',

    init() {
      this.preset = 'general';
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
      this.messages = [];
      this.agentId = null;
      this.status = 'idle';
      this.inputText = '';
      this.errorMsg = '';
      this.pendingContent = '';
    }
  };
}
