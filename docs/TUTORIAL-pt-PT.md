# Tutorial MuulfzOS · Fortnite Edition (pt-PT)

O MuulfzOS é um *playbook* para o [AME Wizard](https://ameliorated.io) que otimiza o Windows 11
para Fortnite competitivo. Os ajustes **não mexem em nada que o anti-cheat ou os torneios
exigem**: Secure Boot, TPM, IOMMU, Defender e assinatura de drivers ficam intactos.

> **Versão 0.9.0 (beta).** Testada em máquinas virtuais com o Windows 11 25H2 e 26H2. Ainda
> falta confirmação em PCs reais a jogar Fortnite, por isso conta-nos como correu.

## Do que precisas

- PC com **Windows 11 24H2, 25H2 ou 26H2** (64 bits)
- **Ligação à Internet**, para o Windows Update e o Epic Games Launcher
- O ficheiro **`MuulfzOSFN-0.9.0.apbx`**, a transferir em [Releases](https://github.com/Muulfz/MuulfzOSFN/releases)
- O **AME Wizard**, a transferir em [ameliorated.io](https://ameliorated.io)
- Para uma instalação de raiz: uma **pen USB de 16 GB ou mais** (vai ser apagada) e o [Rufus](https://rufus.ie)

Há duas formas de instalar. A **instalação de raiz** (opção B) dá o melhor resultado.

---

## Opção A: aplicar no Windows que já tens

1. Instala todas as atualizações no **Windows Update** e reinicia. O AME recusa avançar se houver atualizações pendentes.
2. Abre o **AME Wizard**.
3. Arrasta o `MuulfzOSFN-0.9.0.apbx` para a janela, ou clica em **Use Existing** e escolhe o ficheiro.
4. Segue as páginas e escolhe as opções (vê a secção [Opções do assistente](#opções-do-assistente)).
5. O AME cria um **ponto de restauro**, aplica tudo (cerca de 10 minutos) e reinicia sozinho.

## Opção B: instalação de raiz com pen USB (recomendado)

### 1. Preparar a pen USB

1. Transfere a ISO oficial do Windows 11 no [site da Microsoft](https://www.microsoft.com/pt-pt/software-download/windows11).
2. Abre o **Rufus**, escolhe a pen USB em *Dispositivo*, clica em **SELECIONAR** e escolhe a ISO. Depois clica em **INICIAR**.
3. Na janela *Windows User Experience*:
   - ✅ *Remove requirement for an online Microsoft account*
   - ✅ *Disable data collection (Skip privacy questions)*
   - ✅ *Disable BitLocker automatic device encryption*
   - ⬜ *Create a local account with username*: **deixa desmarcado**, para criares a tua conta durante a instalação.
   - ⬜ *Remove requirement for 4GB+ RAM, Secure Boot and TPM 2.0*: **deixa desmarcado**, porque os torneios exigem estas três coisas.
4. Quando o Rufus terminar, copia para a pen USB o **AME Wizard** e o **`MuulfzOSFN-0.9.0.apbx`**.

### 2. Configurar a BIOS

Para poderes jogar torneios (exigência da Epic desde fevereiro de 2026), liga estas três opções:

- **Secure Boot**
- **TPM**: *fTPM* nas AMD, *PTT* nas Intel
- **IOMMU**: *AMD-Vi / IOMMU* nas AMD, *VT-d* nas Intel

Depois, arranca a partir da pen USB em modo **UEFI**.

### 3. Instalar o Windows

1. Instala normalmente. No ecrã da conta, **cria o teu utilizador e palavra-passe**.
2. Liga-te à Internet, deixa o **Windows Update** terminar e **reinicia**.
3. Instala o driver da placa gráfica (NVIDIA App ou AMD Adrenalin).

### 4. Aplicar o MuulfzOS

1. Na pen USB, abre o **AME Wizard**.
2. Clica em **Use Existing** e escolhe o `MuulfzOSFN-0.9.0.apbx`.
3. Segue as páginas, escolhe as opções e confirma. O PC reinicia sozinho no fim.

---

## Opções do assistente

| Página | Opção | Por omissão | Quando mudar |
|---|---|---|---|
| Fortnite | Desativar VBS / Memory Integrity (+5 a 8% de FPS) | ✅ | **Desmarca** se também jogas Valorant ou FACEIT: o anti-cheat deles exige o Memory Integrity. |
| | Fortnite com prioridade de CPU alta | ✅ | |
| | Ryzen X3D com 2 CCDs: manter o plano Equilibrado | ⬜ | **Marca** se tens um 7900X3D, 7950X3D, 9900X3D ou 9950X3D. |
| | Bloquear drivers pelo Windows Update | ⬜ | Marca se instalas os drivers gráficos à mão e não queres que o Windows os troque. |
| Performance | Agrupar serviços em menos processos | ⬜ | Opcional: menos processos em segundo plano. |
| | Desligar a compressão de memória (16 GB+) | ⬜ | Opcional. Só atua com 16 GB ou mais de RAM. |
| | Desligar o Fault Tolerant Heap | ⬜ | Opcional. |
| Software e aspeto | Instalar o Epic Games Launcher | ✅ | |
| | Fundo de ecrã e ecrã de bloqueio MuulfzOS | ✅ | Desmarca se preferires o teu fundo. |

## Depois de instalar

Na área de trabalho aparece o ficheiro **"Fortnite - MuulfzOSFN.txt"**. Mostra três coisas:

- se o PC está **pronto para torneios** (Secure Boot, TPM e IOMMU);
- se há **filtros de rede de terceiros** a atrasar os pacotes (Killer, VPNs, "boosters");
- as **definições do jogo** que mais aliviam a CPU no fim da partida:
  - **Modo de renderização:** Desempenho (Performance)
  - **NVIDIA Reflex:** Ligado + Boost
  - **Distância de visão:** Perto. **Sombras:** Desligadas. **Efeitos:** Baixo. **Malhas:** Baixo.
  - **Repetições (Replays):** desliga todas as opções de gravação.
  - **Limite de FPS:** o valor que consegues manter no fim da partida, ou a taxa de atualização do monitor − 3 com G-Sync/FreeSync.

## Perguntas frequentes

**Posso ser banido?** O MuulfzOS não toca no jogo nem no anti-cheat. Só muda definições do Windows e mantém tudo o que o Easy Anti-Cheat verifica.

**Funciona em portáteis?** Sim. Em portáteis o plano de energia fica em Equilibrado e os ajustes só para desktop (hibernação, poupança de energia USB/PCIe) não são aplicados.

**Como desfaço?** O AME cria um ponto de restauro antes de aplicar; usa o *Restauro do sistema*. Em último caso, reinstala o Windows.

**O Windows Update continua a funcionar?** Sim. Só deixa de reiniciar o PC entre as 10:00 e as 04:00.

**Algo correu mal?** Abre uma *issue* em [github.com/Muulfz/MuulfzOSFN/issues](https://github.com/Muulfz/MuulfzOSFN/issues) com uma captura de ecrã.
