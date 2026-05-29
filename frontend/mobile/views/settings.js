import { fetchConfig, updateConfig, fetchOllamaModels } from '../../modules/api.js';
import { esc, toast } from '../util.js';

const PROVIDERS = [
    { v: 'gemini', label: 'Google Gemini', icon: 'auto_awesome' },
    { v: 'anthropic', label: 'Anthropic Claude', icon: 'psychology' },
    { v: 'openai', label: 'OpenAI GPT', icon: 'memory' },
    { v: 'ollama', label: 'Ollama (lokaal)', icon: 'dns' },
    { v: 'custom', label: 'Custom (OpenAI-compat)', icon: 'tune' },
];

let _config = null;
let _provider = 'gemini';

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg max-w-2xl mx-auto">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">AI-instellingen</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Kies je AI-provider voor analyse en generatie.</p>
        </section>

        <div id="set-env" class="hidden glass-panel rounded-xl p-md border border-secondary/30 bg-secondary/5">
            <p class="font-body-sm text-body-sm text-secondary">Provider is via een omgevingsvariabele ingesteld; wijzigingen hier worden mogelijk genegeerd.</p>
        </div>

        <section class="glass-panel rounded-xl p-md flex flex-col gap-sm">
            <label class="font-label-caps text-label-caps text-text-muted">PROVIDER</label>
            <div class="relative">
                <select id="set-provider" class="w-full bg-surface-charcoal border border-white/10 rounded-lg py-3 px-4 font-body-lg text-body-lg text-text-primary appearance-none focus:outline-none focus:border-primary">
                    ${PROVIDERS.map((p) => `<option value="${p.v}">${esc(p.label)}</option>`).join('')}
                </select>
                <span class="material-symbols-outlined absolute right-3 top-3 text-text-muted pointer-events-none">expand_more</span>
            </div>
        </section>

        <section id="set-cloud" class="glass-panel rounded-xl p-md flex flex-col gap-sm">
            <label class="font-label-caps text-label-caps text-text-muted">API-SLEUTEL</label>
            <input id="set-apikey" type="password" autocomplete="off" class="w-full bg-surface-glass border border-white/10 rounded-full py-3 px-4 font-body-sm text-body-sm text-text-primary focus:outline-none focus:border-primary" />
            <p class="font-body-sm text-[12px] text-text-muted">Laat leeg om de bestaande sleutel te behouden.</p>
        </section>

        <section id="set-ollama" class="hidden glass-panel rounded-xl p-md flex flex-col gap-sm">
            <label class="font-label-caps text-label-caps text-text-muted">OLLAMA BASE URL</label>
            <input id="set-ollama-url" type="text" class="w-full bg-surface-glass border border-white/10 rounded-full py-3 px-4 font-body-sm text-body-sm text-text-primary focus:outline-none focus:border-primary" placeholder="http://localhost:11434" />
            <button id="set-ollama-refresh" class="self-end font-label-caps text-label-caps text-primary flex items-center gap-1"><span class="material-symbols-outlined text-[16px]">sync</span> MODELLEN VERVERSEN</button>
            <div id="set-ollama-models" class="flex flex-col gap-sm"></div>
        </section>

        <section id="set-custom" class="hidden glass-panel rounded-xl p-md flex flex-col gap-sm">
            <label class="font-label-caps text-label-caps text-text-muted">CUSTOM BASE URL</label>
            <input id="set-custom-url" type="text" class="w-full bg-surface-glass border border-white/10 rounded-full py-3 px-4 font-body-sm text-body-sm text-text-primary focus:outline-none focus:border-primary" placeholder="https://openrouter.ai/api/v1" />
            <label class="font-label-caps text-label-caps text-text-muted mt-sm">MODEL</label>
            <input id="set-custom-model" type="text" class="w-full bg-surface-glass border border-white/10 rounded-full py-3 px-4 font-body-sm text-body-sm text-text-primary focus:outline-none focus:border-primary" />
        </section>

        <section id="set-models" class="glass-panel rounded-xl p-md flex flex-col gap-sm">
            <h3 class="font-title-md text-title-md text-primary flex items-center gap-2"><span class="material-symbols-outlined text-[20px]">tune</span> Actieve modellen</h3>
            <div class="flex justify-between"><span class="font-body-sm text-body-sm text-text-muted">Analyse</span><span id="set-model-analysis" class="font-body-sm text-body-sm text-text-primary">—</span></div>
            <div class="flex justify-between"><span class="font-body-sm text-body-sm text-text-muted">Generatie</span><span id="set-model-generation" class="font-body-sm text-body-sm text-text-primary">—</span></div>
        </section>

        <button id="set-save" class="w-full h-14 viola-gradient text-on-primary font-title-md text-title-md rounded-full flex items-center justify-center gap-2 active:scale-95 transition-transform shadow-[0_4px_24px_rgba(211,187,255,0.25)]">
            <span class="material-symbols-outlined">save</span> Opslaan
        </button>

        <a href="/?view=settings" class="text-center font-label-caps text-label-caps text-text-muted py-sm">Alle instellingen (desktop) →</a>
    </div>`;
}

export async function mount(root) {
    _config = await fetchConfig().catch(() => null);
    if (_config) {
        _provider = _config.llm_provider || 'gemini';
        root.querySelector('#set-provider').value = _provider;
        root.querySelector('#set-ollama-url').value = _config.ollama_url || 'http://localhost:11434';
        root.querySelector('#set-custom-url').value = _config.custom_url || '';
        root.querySelector('#set-custom-model').value = _config.model_analysis || '';
        root.querySelector('#set-apikey').placeholder = _config.llm_api_key_set ? '•••••••• (ingesteld)' : 'Voer API-sleutel in';
        root.querySelector('#set-model-analysis').textContent = _config.model_analysis || '—';
        root.querySelector('#set-model-generation').textContent = _config.model_generation || '—';
        root.querySelector('#set-env').classList.toggle('hidden', !_config.provider_from_env);
    }
    applyProviderVisibility(root);

    root.querySelector('#set-provider')?.addEventListener('change', (e) => { _provider = e.target.value; applyProviderVisibility(root); });
    root.querySelector('#set-ollama-refresh')?.addEventListener('click', () => loadOllamaModels(root));
    root.querySelector('#set-save')?.addEventListener('click', (e) => save(root, e.currentTarget));
}

function applyProviderVisibility(root) {
    const isOllama = _provider === 'ollama';
    const isCustom = _provider === 'custom';
    root.querySelector('#set-cloud').classList.toggle('hidden', isOllama || isCustom);
    root.querySelector('#set-ollama').classList.toggle('hidden', !isOllama);
    root.querySelector('#set-custom').classList.toggle('hidden', !isCustom);
    if (isOllama) loadOllamaModels(root);
}

async function loadOllamaModels(root) {
    const el = root.querySelector('#set-ollama-models');
    if (!el) return;
    const url = root.querySelector('#set-ollama-url').value.trim() || 'http://localhost:11434';
    el.innerHTML = `<div class="flex justify-center py-sm"><span class="material-symbols-outlined animate-spin text-primary">progress_activity</span></div>`;
    let models;
    try { models = await fetchOllamaModels(url); } catch { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen verbinding met Ollama.</p>`; return; }
    const list = models?.models || models || [];
    const names = list.map((m) => m.name || m).filter(Boolean);
    if (!names.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen modellen gevonden.</p>`; return; }
    const opts = names.map((n) => `<option value="${esc(n)}">${esc(n)}</option>`).join('');
    const cur = _config?.model_analysis;
    const curGen = _config?.model_generation;
    el.innerHTML = `
        <label class="font-body-sm text-body-sm text-text-muted">Analyse-model</label>
        <select id="set-ollama-analysis" class="w-full bg-surface-charcoal border border-white/10 rounded-lg py-2 px-3 font-body-sm text-body-sm text-text-primary">${opts}</select>
        <label class="font-body-sm text-body-sm text-text-muted mt-sm">Generatie-model</label>
        <select id="set-ollama-generation" class="w-full bg-surface-charcoal border border-white/10 rounded-lg py-2 px-3 font-body-sm text-body-sm text-text-primary">${opts}</select>`;
    if (cur && names.includes(cur)) el.querySelector('#set-ollama-analysis').value = cur;
    if (curGen && names.includes(curGen)) el.querySelector('#set-ollama-generation').value = curGen;
}

async function save(root, btn) {
    const updates = { llm_provider: _provider };
    if (_provider === 'ollama') {
        const url = root.querySelector('#set-ollama-url').value.trim();
        if (url) updates.ollama_url = url;
        const a = root.querySelector('#set-ollama-analysis')?.value;
        const g = root.querySelector('#set-ollama-generation')?.value;
        if (a) updates.model_analysis = a;
        if (g) updates.model_generation = g;
    } else if (_provider === 'custom') {
        const url = root.querySelector('#set-custom-url').value.trim();
        const model = root.querySelector('#set-custom-model').value.trim();
        const key = root.querySelector('#set-apikey').value.trim();
        if (url) updates.custom_url = url;
        if (model) { updates.model_analysis = model; updates.model_generation = model; }
        if (key) updates.llm_api_key = key;
    } else {
        const key = root.querySelector('#set-apikey').value.trim();
        if (key) updates.llm_api_key = key;
    }

    btn.disabled = true;
    try {
        await updateConfig(updates);
        _config = await fetchConfig().catch(() => _config);
        if (_config) {
            root.querySelector('#set-model-analysis').textContent = _config.model_analysis || '—';
            root.querySelector('#set-model-generation').textContent = _config.model_generation || '—';
            root.querySelector('#set-apikey').value = '';
            root.querySelector('#set-apikey').placeholder = _config.llm_api_key_set ? '•••••••• (ingesteld)' : 'Voer API-sleutel in';
        }
        toast('Instellingen opgeslagen');
    } catch (e) {
        toast(e.message || 'Opslaan mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}
