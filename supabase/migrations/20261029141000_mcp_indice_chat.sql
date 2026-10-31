-- =============================================================================
-- MCP (fase 3): índice de cobertura para as métricas de atendimento.
--
-- EXECUTAR FORA DE TRANSAÇÃO (CREATE INDEX CONCURRENTLY), em horário de menor
-- movimento. Não bloqueia os inserts do n8n, mas leva alguns minutos em
-- chat_messages (~3 milhões de linhas).
--
-- Motivo: idx_chat_messages_empresa_timestamp não inclui message_type nem
-- instance_id, então contar áudios/ligações ou filtrar por instância exige ler a
-- tabela. Medido em 2026-10-29 na maior loja (30 dias, ~60 mil mensagens):
-- mapa_demanda 0,6s sem filtro de tipo vs 7,4s com; ligacoes 1,6–4s; visão geral 3,6s.
-- Com este índice as consultas viram index-only scan.
--
-- Depois de criado, avaliar remover idx_chat_messages_empresa_timestamp (este o cobre).
-- =============================================================================

create index concurrently if not exists idx_chat_messages_mcp_cobertura
  on public.chat_messages (empresa_id, "timestamp")
  include (conversation_id, direction, message_type, instance_id);
