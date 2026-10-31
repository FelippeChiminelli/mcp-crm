import logging

from fastmcp import FastMCP
from fastmcp.server.auth import AuthProvider
from fastmcp.server.auth.providers.supabase import SupabaseProvider
from starlette.requests import Request
from starlette.responses import JSONResponse

from app import prompts
from app.core.access import AccessMiddleware
from app.core.audit import AuditMiddleware
from app.core.config import get_settings
from app.tools import atendimento, comercial, contexto, conversas, funil, marketing

INSTRUCOES = """\
Você está conectado ao Aucta CRM, um CRM para lojas de veículos, com acesso somente
leitura aos dados da loja do usuário (leads, funil, vendas, estoque, anúncios, campanhas
e atendimento no WhatsApp). Comece chamando `info_loja` para conhecer pipelines, etapas, equipe e
instâncias de WhatsApp. Responda em português do Brasil, cite os períodos analisados
e deixe claro quando um dado é estimado ou incompleto. Sem datas, as ferramentas usam
os últimos 30 dias (fuso de São Paulo); o período máximo por consulta é de 93 dias.
Telefones e e-mails vêm mascarados de propósito.

No WhatsApp, "cliente" e "loja" já vêm traduzidos. Mensagens da loja incluem vendedores,
saudação automática, IA de atendimento e campanhas; tempos são corridos (sem descontar a
noite), então considere o horário de funcionamento antes de apontar falhas.
"""


def criar_servidor(auth: AuthProvider | None = None) -> FastMCP:
    mcp = FastMCP(
        name="Aucta CRM",
        instructions=INSTRUCOES,
        auth=auth,
        # Ordem: auditoria envolve o controle de acesso (registra também as negações)
        middleware=[AuditMiddleware(), AccessMiddleware()],
        mask_error_details=True,
    )

    @mcp.custom_route("/health", methods=["GET"], include_in_schema=False)
    async def health(_: Request) -> JSONResponse:
        return JSONResponse({"status": "ok"})

    contexto.registrar(mcp)
    comercial.registrar(mcp)
    funil.registrar(mcp)
    marketing.registrar(mcp)
    atendimento.registrar(mcp)
    conversas.registrar(mcp)
    prompts.registrar(mcp)
    return mcp


def _auth_supabase() -> SupabaseProvider:
    settings = get_settings()
    return SupabaseProvider(
        project_url=settings.SUPABASE_URL,
        base_url=settings.BASE_URL,
        algorithm=settings.SUPABASE_JWT_ALGORITHM,  # pyright: ignore[reportArgumentType]
        resource_name="Aucta CRM",
    )


def criar_app():
    logging.basicConfig(level=get_settings().LOG_LEVEL)
    return criar_servidor(auth=_auth_supabase()).http_app(path="/mcp")
