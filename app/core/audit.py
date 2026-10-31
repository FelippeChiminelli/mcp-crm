"""Registra cada chamada de ferramenta em mcp_audit_log (via mcp_log_call)."""

import logging
import time

from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_access_token
from fastmcp.server.middleware import Middleware

from app.core import supabase

logger = logging.getLogger(__name__)


async def _registrar(
    token: str, ferramenta: str, parametros: dict | None, duracao_ms: int, erro: str | None
) -> None:
    try:
        await supabase.rpc(
            "mcp_log_call",
            token,
            {
                "p_ferramenta": ferramenta,
                "p_parametros": parametros or {},
                "p_duracao_ms": duracao_ms,
                "p_erro": erro,
            },
        )
    except Exception:
        # Falha de auditoria não pode derrubar a resposta para o usuário
        logger.exception("Falha ao registrar auditoria de %s", ferramenta)


class AuditMiddleware(Middleware):
    async def on_call_tool(self, context, call_next):
        inicio = time.perf_counter()
        erro: str | None = None
        try:
            return await call_next(context)
        except ToolError as exc:
            erro = str(exc)
            raise
        except Exception as exc:
            erro = f"{type(exc).__name__}: {exc}"
            raise
        finally:
            access_token = get_access_token()
            if access_token is not None:
                await _registrar(
                    access_token.token,
                    context.message.name,
                    context.message.arguments,
                    int((time.perf_counter() - inicio) * 1000),
                    erro,
                )
