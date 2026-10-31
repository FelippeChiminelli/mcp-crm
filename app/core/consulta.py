"""Chamada padrão das funções SQL do MCP: contexto, erros amigáveis e máscara."""

from typing import Any
from uuid import UUID

from fastmcp.exceptions import ToolError

from app.core import supabase
from app.core.access import MSG_NAO_HABILITADO, contexto_atual
from app.utils.mascara import mascarar

MSG_ERRO_BANCO = "Não foi possível consultar o Aucta CRM agora. Tente novamente em instantes."
MSG_CONSULTA_DEMORADA = (
    "A consulta demorou demais e foi interrompida. Tente um período menor "
    "(por exemplo, 7 ou 15 dias) ou filtre por instância/vendedor."
)


async def consultar(
    funcao: str, params: dict[str, Any] | None = None, *, msg_negado: str = MSG_NAO_HABILITADO
) -> Any:
    ctx = await contexto_atual()
    if params:
        params = {k: str(v) if isinstance(v, UUID) else v for k, v in params.items()}
    try:
        resultado = await supabase.rpc(funcao, ctx.token, params)
    except supabase.AcessoNegadoBanco as exc:
        raise ToolError(msg_negado) from exc
    except supabase.ConsultaDemorada as exc:
        raise ToolError(MSG_CONSULTA_DEMORADA) from exc
    except supabase.ParametroInvalido as exc:
        raise ToolError(str(exc)) from exc
    except supabase.ErroBanco as exc:
        raise ToolError(MSG_ERRO_BANCO) from exc
    return mascarar(resultado)
