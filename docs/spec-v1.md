# Aucta CRM MCP — Especificação v1

Servidor MCP (FastMCP, Python) que permite aos usuários do Aucta CRM conectar seus
assistentes de IA (ChatGPT, Claude e outros clientes MCP) para analisar os dados da
própria loja: funil, vendedores, estoque e, principalmente, qualidade do atendimento
no chat.

## 1. Escopo do v1

| Decisão | v1 |
|---|---|
| Quem pode usar | **Somente admins** (`profiles.is_admin = true`) |
| Operações | **Somente leitura**. Nenhuma ferramenta escreve dados de negócio |
| Isolamento | Por loja (`empresa_id`), garantido pela RLS + checagem de admin |
| Transcrição de áudio | **Fora do v1** (fase 2). Áudios aparecem como "não transcrito" |
| Hospedagem | Serviço separado na VPS, via Easypanel (Docker) |

Fora do escopo do v1: escrita, nível vendedor e transcrição.

### Tabelas que o MCP nunca acessa
- `agente_geg`, `agente_lsouza`, `agente_uniao`, `leads_carro_na_mao`, `leads_fastcarville`
- Sensíveis: `api_tokens`, `credencials_plataforms`, `waba_config`, `meta_capi_config`,
  `whatsapp_instances.token_instance`/`webhook_IA`, `push_subscriptions`

## 2. Por que não usar a `api_crm`

A `api_crm` autentica por **token de empresa** (`adv_live_…`) e consulta com
`service_role`. Ela não sabe *qual usuário* está chamando, então não distingue admin de
vendedor e ignora a RLS. Por isso o MCP fala direto com o Supabase **usando o JWT do
próprio usuário**. Da `api_crm` reaproveitamos convenções (uv, Python 3.12,
pydantic-settings, Dockerfile) e regras de negócio dos seus services como referência.

## 3. Autenticação

### 3.1 Fluxo

```
ChatGPT/Claude ──(1) descobre OAuth──▶ Supabase Auth (OAuth 2.1 server)
      │                                     │
      │◀──(2) registro dinâmico (DCR)────────┤
      │──(3) redireciona usuário──▶ CRM /oauth/consent (login + "Permitir")
      │◀──(4) access token do usuário───────┤
      │
      └──(5) chama ferramenta + Bearer token──▶ crm-mcp (FastMCP)
                                                 │ valida JWT (JWKS)
                                                 │ checa admin + loja ativa
                                                 └─(6) RPC no Supabase com o MESMO token
                                                       → RLS + funções filtram pela loja
```

- O FastMCP usa `SupabaseProvider` (`fastmcp.server.auth.providers.supabase`, ≥ 2.13).
- O MCP **nunca** usa `service_role`. Toda consulta vai ao PostgREST com
  `apikey = anon` e `Authorization: Bearer <token do usuário>`.

### 3.2 Pré-requisitos no Supabase (bloqueantes)

Verificado em 2026-10-29 no projeto `dcvpehjfbpburrtviwhq`:

1. **Migrar para chaves de assinatura JWT assimétricas (ES256).** Hoje o JWKS está
   vazio, ou seja, o projeto assina com o segredo legado HS256, e o `SupabaseProvider`
   valida via JWKS.
   - Fazer em *Settings → JWT Keys*: criar a chave ES256 como standby e então rotacionar.
   - **Não revogar** o segredo legado: as chaves `anon`/`service_role` legadas (usadas
     pelo frontend, `api_crm`, `api_admin`, n8n) continuam válidas enquanto ele não for revogado.
   - Levantamento feito em 2026-10-29:
     - `api_crm` (token próprio + `service_role`) e `api_admin` (`auth.get_user()`) não são afetadas.
     - n8n só usa credenciais `supabaseApi` (API key) e `postgres` (conexão direta), então não é afetado.
     - Edge functions: 5 delas usam `verify_jwt: false` e não são afetadas. **Ponto de atenção:
       `call_webhook` (`verify_jwt: true`)**, chamada pelo frontend com o token do usuário
       (`src/services/metaCapiService.ts`, eventos da Meta CAPI) e pelas automações "Acionar webhook".
       Depois da rotação, os tokens de usuário passam a ser ES256.
   - Procedimento: rotacionar, **testar na hora** um evento da Meta CAPI e uma automação
     "Acionar webhook", e acompanhar os logs da `call_webhook`. Se falhar, desfazer a
     rotação (é reversível no painel) ou desligar o `verify_jwt` dessa função e validar no
     código com `supabase.auth.getClaims()`.
   - As sessões ativas do CRM continuam válidas até expirar.
2. **Habilitar o OAuth 2.1 Server** (*Authentication → OAuth Server*). Está em beta,
   sem custo durante o beta. Hoje o endpoint de discovery retorna 404.
3. **Habilitar Dynamic Client Registration** no mesmo painel.
4. Configurar **Site URL** e **Authorization Path** = `/oauth/consent`.

### 3.3 Mudança no CRM: tela de consentimento

Rota `/oauth/consent` no frontend React:
- Se o usuário não está logado, faz o login normal e volta para a rota.
- Lê os detalhes da autorização (nome do cliente, escopos) via
  `supabase.auth.oauth.getAuthorizationDetails(authorization_id)`.
- **Se o usuário não é admin**, mostra a mensagem "O acesso por IA está disponível apenas
  para administradores" e chama `denyAuthorization`.
- Se a loja não tem o MCP habilitado (ver 3.5), também nega, com a mensagem adequada.
- Caso contrário, mostra o cliente, a loja e o que será acessado (dados de leads,
  vendas e conversas, somente leitura), com os botões **Permitir** e **Negar**.

Mudanças de frontend no v1: esta tela e a tela de configuração (4.1.1).

### 3.4 Guarda de acesso no servidor (a cada chamada)

Middleware FastMCP (`on_call_tool`, `on_list_tools`):
1. Token válido (o `SupabaseProvider` já garante; o `sub` do token é o `auth.uid()`).
2. Busca `profiles` (uuid, empresa_id, is_admin) com o token do usuário. Cache de 60 s por `sub`.
3. Nega se `is_admin` for falso, se `empresas.ativo` for falso ou se a loja não estiver
   habilitada em `mcp_empresa_config`.
4. Anexa `empresa_id`/`user_id` ao contexto para auditoria.

**Defesa em profundidade:** as funções SQL também verificam `is_admin_company(...)`.
Assim, mesmo um vendedor que chame a RPC direto pelo navegador não recebe nada.

### 3.5 Riscos conhecidos
- **Sem RFC 8707 (resource indicators):** o Supabase não vincula o token a este
  servidor. Um token do próprio CRM web também seria aceito. Isso é aceitável porque
  ele tem o mesmo dono e as mesmas permissões. Avaliar exigir o claim `client_id` no futuro.
- **DCR aberto:** qualquer cliente pode se registrar. A proteção real é o consentimento
  do usuário mais a checagem de admin. Revisar os clientes registrados periodicamente.

## 4. Banco de dados

As migrations do MCP ficam neste repositório, em `supabase/migrations/`, e são aplicadas
no Supabase manualmente (SQL Editor ou MCP do Supabase). Prefixo dos objetos: `mcp_`.

### 4.1 Configuração por loja
```sql
create table public.mcp_empresa_config (
  empresa_id uuid primary key references empresas(id),
  habilitado boolean not null default false,
  permite_conteudo_chat boolean not null default false,   -- ler texto das conversas
  updated_by uuid references profiles(uuid),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
-- RLS: SELECT para membros da empresa; INSERT/UPDATE só para admin da empresa
-- (is_admin_company(empresa_id)). Gerenciado pela tela do CRM (ver 4.1.1).
```

#### 4.1.1 Tela no CRM: Configurações → Integrações → Assistentes de IA
Visível só para admins, com dois interruptores:
- **Permitir conexão com assistentes de IA** (`habilitado`). Ao desligar, o MCP
  passa a negar todas as chamadas da loja imediatamente (o cache de 60 s é o atraso máximo).
- **Permitir que a IA leia o conteúdo das conversas** (`permite_conteudo_chat`). Só
  pode ser ligado se o anterior estiver ligado. Mostra um aviso de LGPD: o texto das
  conversas será enviado ao provedor de IA escolhido pelo usuário (OpenAI, Anthropic etc.).

A tela também mostra o endereço do servidor (`https://mcp.auctatech.com.br/mcp`), um
passo a passo para conectar no ChatGPT e no Claude, e a lista dos últimos acessos
(lida de `mcp_audit_log` via função restrita a admin).

Horário comercial **não** é configurado: a IA considera o contexto (ver 4.4).

### 4.2 Auditoria
```sql
create table public.mcp_audit_log (
  id bigint generated always as identity primary key,
  empresa_id uuid not null, user_id uuid not null,
  ferramenta text not null, parametros jsonb, linhas int,
  duracao_ms int, erro text, created_at timestamptz default now()
);
-- Inserção via função mcp_log_call(...) SECURITY DEFINER que usa auth.uid() e
-- o empresa_id do profile (o cliente não informa user/empresa). Sem SELECT via API.
```

### 4.3 Funções de métricas (RPC)
Regras para **todas** as funções `mcp_*`:
- `LANGUAGE sql|plpgsql STABLE SECURITY INVOKER` (a RLS continua valendo).
- Timeout: o role `authenticated` já tem `statement_timeout = 8s` (verificado). Um
  `SET statement_timeout` dentro da função não teria efeito no comando atual.
- O `empresa_id` vem do profile de `auth.uid()`, **nunca de parâmetro**.
- A primeira linha valida `is_admin_company(v_empresa)` e, se falhar, gera exceção.
- Período obrigatório (`p_inicio`, `p_fim`), limitado a **92 dias**.
- Retorno agregado (contagens, médias, percentis), nunca as mensagens em massa.
- `GRANT EXECUTE` só para `authenticated`.

### 4.4 Definições de negócio

> **Atenção: a direção das mensagens é invertida neste banco.** `direction = 'outbound'`
> é a mensagem **do cliente** e `'inbound'` é a mensagem **da loja** (vendedor, saudação,
> IA ou campanha). Confirmado em 2026-10-29 lendo conversas reais e a função existente
> `_chat_response_waits`. Nas ferramentas, sempre traduzir para `cliente`/`loja`.
> Reaproveitar `_chat_response_waits` e `report_sla_vendedores` (já em produção) na fase 3.
| Conceito | Definição v1 | Observação |
|---|---|---|
| Venda | `status = 'venda_confirmada'` e `sold_at` no período (valor: `sold_value`, senão `value`) | Igual às telas de Analytics do CRM |
| Perda | `status = 'perdido'` e `lost_at` no período | `loss_reason_category` guarda o id de `loss_reasons` ou texto livre legado |
| Lead em aberto | `sold_at` e `lost_at` nulos (mesmo filtro dos índices parciais) | Leads sem pipeline ficam fora de `leads_parados` |
| Lead parado | aberto e `current_stage_since` < agora − N dias | |
| Primeira resposta | primeira mensagem da loja (`inbound`) após a primeira do cliente (`outbound`) | Inclui saudação automática e IA da instância, ver 4.5 |
| Conversa sem resposta | última mensagem é do cliente (`outbound`) e tem mais de X min | X é parâmetro da ferramenta (padrão 30) |
| Follow-up ausente | última mensagem é da loja (`inbound`) há mais de N dias, cliente não respondeu e lead em aberto | N é parâmetro da ferramenta (padrão 2) |

**Horário comercial:** o MCP não filtra nem descarta nada por horário. As métricas de
tempo vêm quebradas por **dia da semana e hora de chegada** da mensagem (fuso
`America/Sao_Paulo`), e as docstrings orientam a IA a perguntar ou inferir o horário da
loja (pelo `mapa_demanda`) antes de concluir que houve falha. Por exemplo, uma mensagem
das 23h respondida às 8h não deve ser tratada como falha.
| Ligação perdida | `message_type='call'` e `metadata->>'resultado'` em (`nao_atendida`,`recusada`,`indisponivel`), sem mensagem da loja (`inbound`) nas X horas seguintes | |
| Tarefa atrasada | `status <> 'concluida'` e `due_date` < agora | `status='atrasada'` nem sempre é atualizado |

### 4.5 Limitações dos dados (documentadas para a IA)
- **Vendas com valor simbólico:** cerca de 16% das vendas dos últimos 90 dias têm valor abaixo
  de R$ 1.000 (ex.: R$ 1). `resumo_funil` e `vendas_periodo` informam `vendas_com_valor_abaixo_de_1000`.
- **Data de entrada de veículos:** em cerca de 37% dos veículos a integração de estoque recria o
  registro a cada sincronização, então `created_at` não é a entrada na loja.
  `estoque_veiculos` informa `data_de_entrada_confiavel`.
- **Não há identificação de quem enviou as mensagens da loja (`inbound`)** (vendedor, saudação, IA da
  instância ou campanha). O tempo de primeira resposta pode estar subestimado em
  instâncias com `IA = true`. Por isso as ferramentas de tempo de resposta oferecem o
  parâmetro `excluir_instancias_ia`.
- `chat_conversations.status` é sempre `active`, e `chat_messages.status` é sempre
  `sent`. Não existe "conversa encerrada" nem "mensagem lida".
- Áudio é cerca de 11,6% das mensagens (30 dias) e não está transcrito.

## 5. Ferramentas (v1)

Convenções:
- Nomes em português, `snake_case`. Docstrings escritas para a IA, explicando quando usar
  a ferramenta e as limitações.
- Datas no formato ISO, interpretadas no fuso `America/Sao_Paulo`. O padrão é os últimos 30 dias.
- Listas paginadas: `limite` (padrão 50, máximo 200) e `cursor`.
- Telefone e e-mail sempre mascarados (`(47) 9****-8458`, `f***@gmail.com`).
- Saída em JSON compacto com campo `observacoes` (avisos para a IA, por exemplo "42% das
  mensagens deste período são áudio não transcrito").

### 5.1 Contexto
| Ferramenta | Retorna |
|---|---|
| `info_loja` | Nome da loja, pipelines e etapas, vendedores (nome e id), instâncias de WhatsApp (nome e se tem IA) e quais permissões estão ativas (conteúdo de chat sim/não) |

### 5.2 Comercial
| Ferramenta | Parâmetros principais | Retorna |
|---|---|---|
| `resumo_funil` | período, pipeline? | Leads por etapa, entradas, vendas, perdas, conversão e tempo médio por etapa |
| `leads_por_origem` | período, pipeline? | Por origem: leads, vendas, conversão, valor vendido, investimento (`origin_investments`) e CPL/CAC |
| `desempenho_vendedores` | período, pipeline? | Por vendedor: leads recebidos, vendas, conversão, valor, perdas por motivo e tarefas atrasadas |
| `motivos_perda` | período, pipeline?, vendedor? | Ranking de `loss_reason_category`, com exemplos de `loss_reason_notes` |
| `leads_parados` | dias, pipeline?, etapa?, vendedor? | Lista paginada de leads em aberto parados há mais de N dias |
| `buscar_lead` | termo (nome/telefone, mín. 3) | Até 10 leads com etapa, status e responsável |
| `detalhar_lead` | lead_id | Dados do lead, histórico de etapas, tarefas, interações e resumo das conversas (sem conteúdo) |
| `tarefas` | período, vendedor?, situacao (atrasadas/pendentes/concluidas) | Contagens e lista |
| `estoque_veiculos` | status?, marca?, dias_em_estoque? | Resumo do estoque (quantidade, faixa de preço, dias em estoque) e lista |
| `vendas_periodo` | período, agrupar_por (dia/semana/mes/vendedor/origem) | Série de vendas (`leads.sold_at` + `product_sales`) |

### 5.3 Atendimento (chat), só métricas
| Ferramenta | Parâmetros principais | Retorna |
|---|---|---|
| `chat_visao_geral` | período, instancia? | Conversas com mensagem e novas, mensagens do cliente e da loja, % de áudio, imagens, ligações e situação atual das conversas novas (classificação igual à do CRM) |
| `tempo_resposta` | período, agrupar_por (total/vendedor/instancia/hora/dia_semana), excluir_instancias_com_ia | Mediana, p90, média e faixas de **todas as esperas** respondidas em até 7 dias (reaproveita `_chat_response_waits`, a mesma base da tela de tempo de resposta do CRM) |
| `conversas_sem_resposta` | minutos, max_dias, vendedor?, instancia? | Clientes esperando agora, por responsável, com lista |
| `followup_ausente` | dias, max_dias, vendedor? | Conversas com lead em aberto em que a loja falou por último e ninguém retomou |
| `ligacoes` | período, instancia?, horas_retorno | Ligações do cliente e da loja por resultado; ligações do cliente perdidas/recusadas sem retorno no prazo |
| `mapa_demanda` | período, instancia? | Dia da semana × hora: mensagens do cliente e mediana de resposta |
| `conversas_orfas` | período | Conversas sem responsável (nem na conversa nem no lead) e/ou sem lead |
| `chat_x_conversao` | período | Conversão dos leads por faixa de primeira resposta |

Notas de implementação (verificado em 2026-10-29):
- `chat_conversations.last_message_at` e `message_count` **não são mantidos** (nulos/zero em
  todas as 144 mil conversas). Tudo é calculado a partir de `chat_messages`
  (helper interno `mcp__conversas_desde`).
- Responsável da conversa = `assigned_user_id` ou, se vazio, o responsável do lead
  (`assigned_user_id` está vazio em ~75% das conversas da maior loja).
- Ligações também têm a direção invertida: `outbound` = o cliente ligou. "perdida" só
  aparece em ligações do cliente (a loja não atendeu).
- As funções de atendimento são `SECURITY DEFINER` para usar helpers privados do CRM; a
  empresa continua vindo só de `mcp_exigir_admin()`.
- Desempenho: exige o índice de cobertura `idx_chat_messages_mcp_cobertura`
  (migration separada, `CREATE INDEX CONCURRENTLY`). Sem ele, na maior loja (30 dias),
  as consultas que olham o tipo da mensagem levaram de 3 a 7s, perto do limite de 8s.
  Timeout vira a mensagem "tente um período menor".

### 5.4 Conversas (conteúdo), exige `permite_conteudo_chat`
| Ferramenta | Parâmetros | Retorna |
|---|---|---|
| `listar_conversas` | período, situacao (todas/aguardando_loja/nunca_respondidas/lead_perdido/lead_vendido/sem_lead), vendedor?, instancia?, limite, offset | Conversas com mensagem no período e métricas, **sem conteúdo** |
| `ler_conversa` | conversa_id, max_mensagens (padrão 100, máx. 300), antes_de (cursor) | Mensagens em ordem cronológica (`cliente`/`loja`, horário). Mídias viram marcadores (`[áudio — não transcrito]`, `[imagem] legenda`, `[documento: nome]`, `[ligação] …`). Sequências de 10+ dígitos (CPF, telefone, cartão) e e-mails no texto são mascarados no servidor |
| `amostrar_conversas` | período, criterio (qualquer/lead_perdido/lead_vendido/aguardando_loja/nunca_respondidas), quantidade (máx. 20), vendedor? | Amostra aleatória de ids e total de candidatas |

Dupla checagem da permissão: o servidor esconde e bloqueia as ferramentas com a tag
`conteudo_chat`, e o banco recusa via `mcp_exigir_conteudo_chat()` (vale mesmo com o cache
de 60 s do servidor desatualizado). Validado em 2026-10-29: `ler_conversa` levou 24 ms e
uma conversa de outra loja retornou `null`.

**Prompt injection:** o conteúdo das conversas vem de clientes externos. `ler_conversa`
delimita o texto como dado (`<conversa>…</conversa>`) e a docstring instrui a IA a não
seguir instruções contidas nele. Como o MCP é somente leitura, o dano possível é limitado.

### 5.5 Prompts (roteiros prontos)
- `auditoria_atendimento(vendedor, periodo)`: amostra conversas e avalia cumprimento,
  coleta de dados, oferta de test drive/visita, apresentação de preço/financiamento,
  próximo passo e follow-up.
- `diagnostico_perdas(periodo)`: cruza motivos de perda, tempo de resposta e amostra
  de conversas perdidas.
- `resumo_semanal()`: funil, vendas, gargalos de atendimento e 3 ações recomendadas.

Os prompts instruem a IA a **sinalizar quando a conclusão se baseia em conversas com
muito áudio não transcrito**.

## 6. Projeto (`crm-mcp`)

```
crm-mcp/
├── pyproject.toml          # uv, Python 3.12, fastmcp>=2.13, httpx, pydantic-settings
├── Dockerfile              # mesmo padrão da api_crm
├── .env.example
├── app/
│   ├── server.py           # FastMCP + SupabaseProvider + middlewares
│   ├── core/
│   │   ├── config.py       # SUPABASE_URL, SUPABASE_ANON_KEY, BASE_URL, JWT_ALGORITHM
│   │   ├── supabase.py     # cliente PostgREST por requisição (anon key + token do usuário)
│   │   ├── access.py       # middleware: admin, loja ativa, habilitada, cache
│   │   └── audit.py        # middleware: mcp_log_call
│   ├── tools/
│   │   ├── contexto.py
│   │   ├── comercial.py
│   │   ├── atendimento.py
│   │   └── conversas.py
│   ├── prompts.py
│   └── utils/
│       ├── mascara.py      # telefone, e-mail, CPF
│       └── periodo.py      # validação de período e fuso
└── tests/
    ├── test_mascara.py
    ├── test_periodo.py
    └── test_isolamento.py  # integração: usuários de teste em 2 lojas + 1 vendedor
```

Variáveis de ambiente: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `BASE_URL` (URL pública
do MCP), `SUPABASE_JWT_ALGORITHM=ES256`, `LOG_LEVEL`. **Não existe** variável de `service_role`.

## 7. Deploy (Easypanel)
- App a partir do Dockerfile, com domínio próprio `mcp.auctatech.com.br` e HTTPS (obrigatório para OAuth).
- Transporte **Streamable HTTP** em `/mcp`.
- Healthcheck em `/health` (rota customizada, sem autenticação).
- Uma réplica no v1. O cache de profile é em memória.

## 8. Testes e critérios de aceite
- **Isolamento (bloqueante para produção):** com usuários de teste
  (admin da loja A, admin da loja B e vendedor da loja A), validar que:
  - o admin A nunca vê dados de B em nenhuma ferramenta;
  - o vendedor A recebe "acesso negado" no MCP **e** na chamada direta das RPCs `mcp_*`;
  - um token inválido ou expirado retorna 401.
- Conferir as métricas contra as telas do CRM para uma loja piloto (funil, vendas e tempo de resposta).
- Desempenho: cada ferramenta abaixo de 3 s para 30 dias na maior loja, com `EXPLAIN` nas funções de chat.
- Teste real conectando ChatGPT e Claude.ai pelo fluxo OAuth completo.

## 9. Fases de entrega
0. **Pré-requisitos:** chaves JWT ES256 (com o teste da `call_webhook`), OAuth server,
   DCR, tela `/oauth/consent` e tela "Assistentes de IA" no CRM.
1. **Fundação:** esqueleto, auth, guarda de acesso, auditoria, `info_loja` funcionando
   de ponta a ponta no ChatGPT e no Claude, deploy no Easypanel.
2. **Comercial:** ferramentas 5.2 e as funções SQL correspondentes.
3. **Atendimento:** ferramentas 5.3 (as mais pesadas, com foco em índices e `EXPLAIN`).
4. **Conversas e prompts:** 5.4 e 5.5.
5. **Piloto:** 2 ou 3 lojas habilitadas, ajustes, depois abertura gradual.

Fase 2 do produto (fora do v1): transcrição de áudio (worker separado), nível vendedor
(filtro no MCP espelhando o frontend, mais `user_pipeline_permissions`/`user_stage_permissions`)
e transcrição de áudio.

## 10. Questões em aberto
1. ~~Domínio~~ → **`mcp.auctatech.com.br`** (produção).
2. ~~JWT legado~~ → verificado: só a `call_webhook` exige teste na rotação (ver 3.2).
3. ~~Horário comercial~~ → não configurado; a IA interpreta (ver 4.4).
4. ~~Conteúdo de chat~~ → interruptor separado, ligado pelo admin da loja no CRM (ver 4.1.1).
5. ~~Ambiente de teste~~ → **usuários de teste em produção**: duas empresas de teste
   ("MCP Teste A" e "MCP Teste B"), cada uma com um admin, e um vendedor na A, com
   alguns leads e conversas fictícios. Nunca usar lojas reais nos testes.
