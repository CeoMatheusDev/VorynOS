//************************************************************************//
//  AGENTS.md                                                            //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# VorynOS — protocolo de engenharia

**Leia `internal/ai/AGENTS.md` por completo antes de agir neste
repositório.** Este arquivo é o ponto de entrada: as ferramentas de
programação descobrem automaticamente um arquivo `AGENTS.md` na raiz do
repositório, e o protocolo normativo do projeto mora em
`internal/ai/AGENTS.md`, junto com os demais documentos de desenvolvimento.

Em resumo, o que o protocolo exige:

1. Implementação antes de abstração: nenhum componente existe sem código
   real, sem testes e sem documentação.
2. Verificação antes de afirmação: nada é declarado funcionando sem
   comando executado e evidência real.
3. Documentação como parte do incremento: toda decisão com custo ou risco
   vira ADR, e toda interface estável vira especificação.
4. O estado que vale é o estado **verificado**: o roadmap e as notas de
   versão descrevem o código publicado, e não a intenção.
5. O `AGENTS.md` é normativo: quando ele e qualquer outro documento
   divergirem, ele prevalece.

O protocolo completo está em [`internal/ai/AGENTS.md`](internal/ai/AGENTS.md).
