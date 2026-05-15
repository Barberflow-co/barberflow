-- =============================================================================
-- Migration 001 — Auditoria de isolamento de tenants em `equipe`
-- =============================================================================
--
-- PROPÓSITO:
--   Detectar registros corrompidos pela vulnerabilidade de identificação de
--   tenant que existia em `loadCtx`/`doRegister` antes do commit que acompanha
--   este arquivo (busca primária por email em vez de auth_user_id).
--
-- COMO USAR:
--   1. Abra o SQL Editor do Supabase do projeto Klipflow.
--   2. Rode cada bloco numerado abaixo, UM DE CADA VEZ.
--   3. Cole o resultado de volta no chat com o Claude para decidirmos o cleanup.
--
-- IMPORTANTE:
--   * Este arquivo é READ-ONLY por padrão. Só há SELECTs ativos.
--   * Os blocos de ALTER / CREATE / UPDATE estão COMENTADOS no final.
--     NÃO descomente sem revisar comigo o resultado dos SELECTs antes.
--   * Não rode tudo de uma vez. Cada cenário tem um significado distinto.
--
-- =============================================================================


-- -----------------------------------------------------------------------------
-- CENÁRIO A — Ex-funcionário recadastrado
-- -----------------------------------------------------------------------------
-- O mesmo email aparece em mais de uma linha de `equipe` (mais de uma
-- barbearia). Causa típica: ex-funcionário não foi removido e foi
-- recontratado por outra barbearia. Pode causar login na tenant errada
-- porque o lookup antigo (`.eq('email', ...)`) não garantia ordem.
--
-- Esperado em base limpa: 0 linhas retornadas.
-- -----------------------------------------------------------------------------
SELECT
  email,
  COUNT(*)                AS qtd_registros,
  array_agg(id)           AS ids_equipe,
  array_agg(user_id)      AS barbearias_dono,
  array_agg(auth_user_id) AS auth_user_ids
FROM equipe
GROUP BY email
HAVING COUNT(*) > 1
ORDER BY qtd_registros DESC, email;


-- -----------------------------------------------------------------------------
-- CENÁRIO B — auth_user_id apontando para um auth.users com EMAIL DIFERENTE
-- -----------------------------------------------------------------------------
-- A linha de `equipe` está vinculada (via auth_user_id) a uma conta do
-- Supabase Auth cujo email NÃO bate com o email do registro. Sinal forte
-- de auto-vinculação errada herdada do código antigo, OU de troca de email
-- do funcionário sem reflexo no `equipe.email`.
--
-- Esperado em base limpa: 0 linhas retornadas.
-- -----------------------------------------------------------------------------
SELECT
  e.id              AS equipe_id,
  e.user_id         AS barbearia_dono,
  e.email           AS equipe_email,
  e.auth_user_id    AS vinculado_a,
  u.email           AS auth_email,
  e.nome            AS equipe_nome,
  e.permissao
FROM equipe e
JOIN auth.users u ON u.id = e.auth_user_id
WHERE LOWER(e.email) <> LOWER(u.email);


-- -----------------------------------------------------------------------------
-- CENÁRIO C — Dono (admin) sequestrado para a equipe de outra barbearia
-- -----------------------------------------------------------------------------
-- Um id de `profiles` (dono de barbearia X) também aparece como
-- `equipe.auth_user_id` em barbearia Y. Sob o código antigo, esse dono
-- entrava como funcionário da Y em vez de admin da própria barbearia.
--
-- Esperado em base limpa: 0 linhas retornadas.
-- -----------------------------------------------------------------------------
SELECT
  p.id                  AS profile_id,
  p.email               AS dono_email,
  p.nome_barbearia      AS barbearia_propria,
  e.id                  AS equipe_id_que_capturou,
  e.user_id             AS barbearia_que_capturou,
  e.permissao           AS permissao_capturada,
  e.email               AS email_no_registro_equipe
FROM profiles p
JOIN equipe e ON e.auth_user_id = p.id
WHERE p.id <> e.user_id;


-- -----------------------------------------------------------------------------
-- CENÁRIO D — Membros de equipe pendentes (sem auth_user_id)
-- -----------------------------------------------------------------------------
-- Lista quantos registros ainda estão "aguardando vínculo". Sob o código
-- novo, esses são auto-vinculados no primeiro login SE forem únicos por
-- email. Múltiplos pendentes com mesmo email ficam BLOQUEADOS aguardando
-- intervenção manual (mesma query do Cenário A, mas só pendentes).
--
-- Esperado em base normal: pode haver alguns pendentes legítimos
-- (funcionários ainda não acessaram pela primeira vez).
-- -----------------------------------------------------------------------------
SELECT
  email,
  COUNT(*)              AS qtd_pendentes,
  array_agg(id)         AS ids_equipe,
  array_agg(user_id)    AS barbearias_dono
FROM equipe
WHERE auth_user_id IS NULL
GROUP BY email
HAVING COUNT(*) > 1
ORDER BY qtd_pendentes DESC, email;


-- -----------------------------------------------------------------------------
-- VISÃO GERAL — distribuição de status de vínculo na tabela `equipe`
-- -----------------------------------------------------------------------------
-- Útil para dimensionar o problema antes de qualquer correção.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                    AS total_registros,
  COUNT(*) FILTER (WHERE auth_user_id IS NOT NULL) AS vinculados,
  COUNT(*) FILTER (WHERE auth_user_id IS NULL)     AS pendentes,
  COUNT(DISTINCT email)                       AS emails_distintos,
  COUNT(DISTINCT user_id)                     AS barbearias_distintas
FROM equipe;


-- =============================================================================
-- BLOCOS DESTRUTIVOS — TUDO COMENTADO. Revisar resultados dos SELECTs acima
-- antes de ativar qualquer um. Cada bloco é independente.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- BLOCO 1 — Constraint: cada auth_user_id no máximo 1× em `equipe`
-- -----------------------------------------------------------------------------
-- Bloqueia o caso "mesma conta Supabase vinculada a 2 barbearias".
-- Pré-requisito: o resultado do CENÁRIO B precisa estar VAZIO ou ter sido
-- limpo antes. Caso contrário a criação do índice falha.
-- -----------------------------------------------------------------------------
-- CREATE UNIQUE INDEX IF NOT EXISTS equipe_auth_user_id_unique
--   ON equipe (auth_user_id)
--   WHERE auth_user_id IS NOT NULL;


-- -----------------------------------------------------------------------------
-- BLOCO 2 — Constraint: email único POR barbearia (não global)
-- -----------------------------------------------------------------------------
-- Permite o mesmo email em barbearias diferentes (cenário legítimo de
-- profissional que trabalha em duas), mas impede duplicata interna.
-- -----------------------------------------------------------------------------
-- ALTER TABLE equipe
--   ADD CONSTRAINT equipe_user_id_email_unique UNIQUE (user_id, email);


-- -----------------------------------------------------------------------------
-- BLOCO 3 — Coluna `ativo` para soft-delete de ex-funcionários
-- -----------------------------------------------------------------------------
-- Hoje não existe forma de marcar um membro como desligado sem apagar a
-- linha. Adicionar essa coluna permite manter histórico e filtrar dos
-- lookups sem perder os dados de comissão/agendamentos antigos.
-- Após o ALTER, o código JS precisa passar a filtrar `.eq('ativo', true)`
-- nas leituras de `equipe`. NÃO fazer só o ALTER sem o JS.
-- -----------------------------------------------------------------------------
-- ALTER TABLE equipe
--   ADD COLUMN ativo BOOLEAN NOT NULL DEFAULT true,
--   ADD COLUMN desligado_em TIMESTAMPTZ;


-- -----------------------------------------------------------------------------
-- BLOCO 4 — Reforço de RLS em `equipe` (DRAFT)
-- -----------------------------------------------------------------------------
-- Política sugerida: SELECT só libera linhas onde o usuário é o dono
-- (user_id = auth.uid()) OU o próprio membro vinculado
-- (auth_user_id = auth.uid()). Bloqueia qualquer tentativa de leitura
-- baseada apenas em email match.
--
-- ANTES de aplicar, verificar as policies existentes:
--   SELECT * FROM pg_policies WHERE tablename = 'equipe';
--
-- A policy abaixo é apenas um DRAFT — pode haver políticas já existentes
-- que precisam ser DROPPADAS primeiro, e o nome dela colide se já existir.
-- -----------------------------------------------------------------------------
-- ALTER TABLE equipe ENABLE ROW LEVEL SECURITY;
--
-- CREATE POLICY equipe_select_dono_ou_membro
--   ON equipe FOR SELECT
--   USING (
--     user_id = auth.uid()
--     OR auth_user_id = auth.uid()
--   );
--
-- CREATE POLICY equipe_insert_dono
--   ON equipe FOR INSERT
--   WITH CHECK (user_id = auth.uid());
--
-- CREATE POLICY equipe_update_dono_ou_self
--   ON equipe FOR UPDATE
--   USING (
--     user_id = auth.uid()
--     OR auth_user_id = auth.uid()
--   );
--
-- CREATE POLICY equipe_delete_dono
--   ON equipe FOR DELETE
--   USING (user_id = auth.uid());


-- =============================================================================
-- FIM — em caso de dúvida, NÃO descomente nada. Mande o resultado dos
-- SELECTs no chat antes.
-- =============================================================================
