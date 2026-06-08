function shem() {
  return {
    preset: 'general',
    presets: ['general'],
    task: '',
    status: 'idle',
    output: '',
    errorMsg: '',
    agentId: null,
    eventSource: null,

    async init() {
      try {
        const res = await fetch('/api/presets');
        const data = await res.json();
        this.presets = data.map(p => p.name);
        if (this.presets.length > 0 && !this.presets.includes(this.preset)) {
          this.preset = this.presets[0];
        }
      } catch (_) {
        // keep default ['general']
      }
    },

    async run() {
      if (this.status === 'running') return;
      this.status = 'running';
      this.output = '';
      this.errorMsg = '';

      let res;
      try {
        res = await fetch('/api/agents', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ preset: this.preset, task: this.task })
        });
      } catch (e) {
        this.status = 'error';
        this.errorMsg = 'Network error: ' + e.message;
        return;
      }

      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        this.status = 'error';
        this.errorMsg = data.error || ('HTTP ' + res.status);
        return;
      }

      let agent_id;
      try {
        ({ agent_id } = await res.json());
      } catch (e) {
        this.status = 'error';
        this.errorMsg = 'Invalid server response.';
        return;
      }
      this.agentId = agent_id;

      const es = new EventSource('/api/agents/' + agent_id + '/stream');
      this.eventSource = es;

      es.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        if (msg.type === 'chunk') {
          this.output += msg.content;
          this.$nextTick(() => {
            const el = this.$refs.outputBody;
            if (el) el.scrollTop = el.scrollHeight;
          });
        } else if (msg.type === 'done') {
          this.status = msg.status === 'error' ? 'error' : 'done';
          if (msg.status === 'error') this.errorMsg = 'Agent finished with an error.';
          es.close();
          this.eventSource = null;
        }
      };

      es.onerror = () => {
        if (this.status === 'running') {
          this.status = 'error';
          this.errorMsg = 'Connection lost.';
        }
        es.close();
        this.eventSource = null;
      };
    },

    async stop() {
      if (this.eventSource) {
        this.eventSource.close();
        this.eventSource = null;
      }
      if (this.agentId) {
        await fetch('/api/agents/' + this.agentId, { method: 'DELETE' }).catch(() => {});
      }
      this.status = 'idle';
      this.agentId = null;
    },

    reset() {
      if (this.eventSource) { this.eventSource.close(); this.eventSource = null; }
      this.output = '';
      this.errorMsg = '';
      this.task = '';
      this.status = 'idle';
      this.agentId = null;
    }
  };
}
