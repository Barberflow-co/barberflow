# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Klipflow — a SaaS for hair-prosthesis barbershops (Portuguese pt-BR). No build step, no framework, no package manager. The repo is a handful of standalone HTML files with inline CSS + vanilla JS, deployed as static files on Vercel. All backend logic lives in Supabase (Postgres + Auth + Realtime + RPC).

There is no `npm install`, no test suite, no linter. Edits go live as soon as Vercel redeploys.

## Files (each is a complete, self-contained app)

- `index.html` (~6700 lines) — the SPA. Contains login/register/forgot pages, the full authenticated dashboard (agenda, clientes, comandas, caixa, relatórios, equipe, etc.), AND the public link-in-bio page (`?p=<slug>`). Everything is one file: CSS in `<style>`, JS in one `<script>` block at the bottom.
- `admin.html` — internal admin panel. Email-gated to `calderarimkt@gmail.com`. Uses the Supabase **service_role** key (`sbAdmin`) to bypass RLS for support operations. Treat changes here as production-impacting.
- `klipflow.html` — marketing landing page. No Supabase, no auth.
- `privacidade.html` / `termos.html` — static legal pages.
- `vercel.json` — host-based routing: `klipflow.com.br` → `klipflow.html`; `app.klipflow.com.br` → `index.html`; everything else → `index.html`.

## Architecture inside `index.html`

The whole SPA hinges on three globals set during `loadCtx()` (around line 6222):

- `CU` — Supabase auth user (`sb.auth.getSession()`).
- `CP` — row from `profiles` (the account owner's profile). Used for trial date, `nome_barbearia`, `link_page` JSON, etc.
- `CE` — row from `equipe` if the logged-in user is a *team member* (a professional/recepção/financeiro the owner created), otherwise `null`.

**Multi-tenant rule:** every Supabase query is scoped by `user_id` via `getOwn()` (index.html:6351):

```js
function getOwn(){return CE?CE.user_id:CU?.id;}
```

If `CE` is set, the user is a team member and reads the *owner's* data. Otherwise they read their own. **Never write a Supabase query against tenant data without `.eq('user_id', getOwn())`** — this is the only thing keeping tenants isolated on the client side (RLS should also enforce it server-side, but the client assumes the filter is present).

Role-based UI is in `PERMS` + `applyPerm()` (around line 6353): `admin` / `financeiro` / `recepcao` / `profissional` toggle CSS classes on nav items. Professionals get further restricted via `aplicarMenuProf()`.

### Page/view model

- "Pages" are top-level `.page` divs (`page-login`, `page-app`, `page-link`, etc.). `go(name)` toggles `.active`.
- Inside `page-app`, "views" are `.view` divs (`view-dashboard`, `view-agenda`, ...). `sv(name, el)` switches them, updates the title, persists the last view to `localStorage` (`bf_page`), and calls the matching `load*()` function.
- Modals are `.mo` divs opened with `om(id)` / closed with `cm(id)`.
- `id(x)` and `v(x)` are the project's getElementById/value helpers — used everywhere.

### Realtime

`ativarRealtime()` (line 6274) subscribes to `postgres_changes` on every relevant table and reloads the active view + dashboard on any change. When adding a new table that should reflect live updates, add it to the `tabelas` array there and add a `load*()` branch in the for-loop.

### Public link-page (`?p=<slug>`)

`init()` calls `verificarLinkPage()` first; if the URL has `?p=<slug>`, it renders `page-link` (the linkbio-style public profile) and returns *before* checking auth. Slug uniqueness is checked by a `LIKE` query against `profiles.link_page` (JSON stored as a string). Don't migrate `link_page` to a real column without updating `verificarLinkPage` and the slug-check query.

### Trial / paywall

`verificarTrial()` computes days from `profiles.created_at`. After `TRIAL_DIAS` (14), the `m-planos` modal opens with close buttons hidden. Payment is currently a WhatsApp deeplink to the founder — no real gateway integration yet (the "Gateways de pagamento" cards on the pagamentos view are static placeholders).

### Supabase tables in use

`profiles`, `clientes`, `agendamentos`, `anamneses`, `equipe`, `servicos`, `estoque`, `comandas`, `caixa`, `retornos`, `proteses_clientes`, `lista_espera`. RPCs called from `admin.html`: `admin_update_plano`, `admin_delete_profile`.

### WhatsApp integration

Direct fetch calls from the browser to a self-hosted Evolution API instance. `EVO_URL` / `EVO_KEY` are hardcoded near line 1965. Instance ID per user is `wa_<CU.id>` (`waInstanciaId()`). Automation runs are throttled with `localStorage` keys (`wa_<kind>_<cliId>_<YYYY-MM-DD>`) to prevent duplicate sends. UI config (toggles, message templates) is also kept in `localStorage` — it is **not** persisted to Supabase, so it doesn't survive a different browser/device.

## Running locally

Open the HTML file directly, or serve the directory with any static server (e.g. `python -m http.server`). For `index.html` to function end-to-end you need network access to the Supabase project at `owanynpsbutuhcaclkif.supabase.co` and (for WhatsApp features) the Evolution API host.

## Conventions to keep in mind

- **Single-file, no modules.** When adding a feature: put HTML in the right `<div class="view">`, CSS at the top `<style>`, JS at the bottom. Don't introduce a build step or split files without discussing it first.
- **Portuguese is the product language.** UI strings, variable names mixing pt-BR (`cliente`, `agendamento`, `equipe`, `caixa`), and toast messages are all in Portuguese. Match the existing style; don't translate.
- **Inline everything.** Styles use single-letter utility classes (`.fi`, `.fg`, `.fl`, `.btn`, `.b-green`, etc.) defined at the top. Reuse them rather than adding new ones.
- **`getOwn()` everywhere.** Any insert/select/update against a tenant table must scope to `user_id: getOwn()`.
- **Secrets in client code.** The Supabase anon key (and in `admin.html`, the service_role key) are committed in plaintext. That's the current state — flag it if it's relevant to a task, but don't refactor it out unilaterally.
- **Always respond in Brazilian Portuguese (pt-BR).** Interface messages from Claude Code itself stay in English, but all analysis, explanations, plans, comments and chat responses must be in pt-BR.
