"""Mascaramento de dados pessoais antes de devolver resultados para a IA."""

import re
from typing import Any

CAMPOS_TELEFONE = {"telefone"}
CAMPOS_EMAIL = {"email"}


def telefone(valor: str | None) -> str | None:
    if not valor:
        return valor
    digitos = re.sub(r"\D", "", valor)
    if len(digitos) >= 12 and digitos.startswith("55"):
        digitos = digitos[2:]
    if len(digitos) < 8:
        return "****"
    if len(digitos) >= 10:
        ddd, numero = digitos[:2], digitos[2:]
        return f"({ddd}) {numero[0]}****-{numero[-4:]}"
    return f"****-{digitos[-4:]}"


def email(valor: str | None) -> str | None:
    if not valor or "@" not in valor:
        return valor
    usuario, dominio = valor.split("@", 1)
    return f"{usuario[:1]}***@{dominio}"


def mascarar(dados: Any) -> Any:
    """Percorre o JSON e mascara os campos de telefone e e-mail."""
    if isinstance(dados, dict):
        resultado = {}
        for chave, valor in dados.items():
            if chave in CAMPOS_TELEFONE and isinstance(valor, str):
                resultado[chave] = telefone(valor)
            elif chave in CAMPOS_EMAIL and isinstance(valor, str):
                resultado[chave] = email(valor)
            else:
                resultado[chave] = mascarar(valor)
        return resultado
    if isinstance(dados, list):
        return [mascarar(item) for item in dados]
    return dados


# Sequências com 10+ dígitos (telefone, CPF, CNPJ, cartão, conta), aceitando
# espaços, pontos, hífens, barras e parênteses no meio. Preços ("R$ 45.900,00")
# têm menos dígitos ou são cortados pela vírgula.
_RE_NUMERO_LONGO = re.compile(r"\+?\(?\d[\d\s.\-/()]{8,}\d")
_RE_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
# Datas (29/10 ou 29/10/2026) e anos (1950-2099) separados por espaço não são dado pessoal
_RE_DATA_OU_ANO = re.compile(r"\d{1,2}/\d{1,2}(/\d{2}|/\d{4})?|(19|20)\d{2}")


def _so_datas_ou_anos(trecho: str) -> bool:
    return all(_RE_DATA_OU_ANO.fullmatch(parte) for parte in trecho.split())


def _mascarar_numero(m: re.Match[str]) -> str:
    trecho = m.group(0)
    digitos = re.sub(r"\D", "", trecho)
    if len(digitos) < 10 or _so_datas_ou_anos(trecho):
        return trecho
    return f"[número oculto …{digitos[-2:]}]"


def texto(valor: str | None) -> str | None:
    """Mascara dados pessoais dentro de texto livre (mensagens de chat)."""
    if not valor:
        return valor
    valor = _RE_EMAIL.sub(lambda m: email(m.group(0)) or "", valor)
    return _RE_NUMERO_LONGO.sub(_mascarar_numero, valor)
