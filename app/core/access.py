"""Quem está chamando e se pode usar o MCP.

O contexto vem de mcp_contexto() (consultado com o token do usuário) e fica em
cache por alguns segundos. As funções SQL repetem a checagem (mcp_exigir_admin),
então este middleware é a primeira barreira, não a única.
"""

import time
from dataclasses import dataclass
from typing import Any

from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_access_token
from fastmcp.server.middleware import Middleware, MiddlewareContext

from app.core import supabase
from app.core.config import get_settings

# Ferramentas que expõem texto das conversas levam esta tag
TAG_CONTEUDO_CHAT = "conteudo_chat"

MSG_SEM_LOGIN = "Sessão inválida ou expirada. Reconecte o Aucta CRM no seu assistente de IA."
MSG_SEM_PERFIL = "Usuário sem cadastro de loja no Aucta CRM."
MSG_NAO_ADMIN = "O acesso por assistentes de IA está disponível apenas para administradores da loja."
MSG_LOJA_INATIVA = "A loja está inativa no Aucta CRM."
MSG_NAO_HABILITADO = (
    "A conexão com assistentes de IA não está habilitada para esta loja. Um administrador "
    "pode ativar em Configurações > Integrações > Assistentes de IA no Aucta CRM."
)
MSG_SEM_CONTEUDO_CHAT = (
    "A leitura do conteúdo das conversas não está habilitada para esta loja. Um administrador "
    "pode ativar em Configurações > Integrações > Assistentes de IA no Aucta CRM."
)


@dataclass(frozen=True)
class Contexto:
    token: str
    user_id: str
    nome: str | None
    empresa_id: str
    empresa_nome: str | None
    is_admin: bool
    empresa_ativa: bool
    habilitado: bool
    permite_conteudo_chat: bool

    def motivo_bloqueio(self) -> str | None:
        if not self.is_admin:
            return MSG_NAO_ADMIN
        if not self.empresa_ativa:
            return MSG_LOJA_INATIVA
        if not self.habilitado:
            return MSG_NAO_HABILITADO
        return None


# sub -> (expira_em, dados de mcp_contexto)
_cache: dict[str, tuple[float, dict[str, Any] | None]] = {}


def limpar_cache() -> None:
    _cache.clear()


async def _dados_contexto(sub: str, token: str) -> dict[str, Any] | None:
    agora = time.monotonic()
    em_cache = _cache.get(sub)
    if em_cache and em_cache[0] > agora:
        return em_cache[1]

    dados = await supabase.rpc("mcp_contexto", token)
    _remover_expirados(agora)
    _cache[sub] = (agora + get_settings().CONTEXTO_CACHE_SEGUNDOS, dados)
    return dados


def _remover_expirados(agora: float) -> None:
    for sub in [s for s, (expira_em, _) in _cache.items() if expira_em <= agora]:
        del _cache[sub]


async def contexto_atual() -> Contexto:
    """Contexto do usuário da requisição atual. Lança ToolError se não houver login/perfil."""
    access_token = get_access_token()
    sub = access_token.claims.get("sub") if access_token else None
    if access_token is None or not sub:
        raise ToolError(MSG_SEM_LOGIN)

    try:
        dados = await _dados_contexto(sub, access_token.token)
    except supabase.AcessoNegadoBanco as exc:
        raise ToolError(MSG_SEM_LOGIN) from exc
    if not dados or not dados.get("empresa_id"):
        raise ToolError(MSG_SEM_PERFIL)

    return Contexto(
        token=access_token.token,
        user_id=dados["user_id"],
        nome=dados.get("nome"),
        empresa_id=dados["empresa_id"],
        empresa_nome=dados.get("empresa_nome"),
        is_admin=bool(dados.get("is_admin")),
        empresa_ativa=bool(dados.get("empresa_ativa")),
        habilitado=bool(dados.get("habilitado")),
        permite_conteudo_chat=bool(dados.get("permite_conteudo_chat")),
    )


async def _tags_da_ferramenta(context: MiddlewareContext[Any], nome: str) -> set[str]:
    if context.fastmcp_context is None:
        return set()
    ferramenta = await context.fastmcp_context.fastmcp.get_tool(nome)
    return set(ferramenta.tags) if ferramenta else set()


class AccessMiddleware(Middleware):
    async def on_list_tools(self, context, call_next):
        ferramentas = await call_next(context)
        try:
            ctx = await contexto_atual()
        except ToolError:
            return ferramentas
        if ctx.permite_conteudo_chat:
            return ferramentas
        return [f for f in ferramentas if TAG_CONTEUDO_CHAT not in f.tags]

    async def on_call_tool(self, context, call_next):
        ctx = await contexto_atual()
        motivo = ctx.motivo_bloqueio()
        if motivo:
            raise ToolError(motivo)
        if not ctx.permite_conteudo_chat and TAG_CONTEUDO_CHAT in await _tags_da_ferramenta(
            context, context.message.name
        ):
            raise ToolError(MSG_SEM_CONTEUDO_CHAT)
        return await call_next(context)
