# AudioConvert

Gravador de áudio do **Apple Music** para macOS. Captura **apenas** o áudio do
processo do Music (via Core Audio *process tap* — sem driver virtual, sem
BlackHole) e salva **um arquivo ALAC (`.m4a`) por faixa**, nomeado e com tags a
partir das notificações de troca de faixa do player. Cada faixa também é
convertida para **MP3 320 kbps** e organizada numa biblioteca por álbum
(`Recordings/Biblioteca/<Álbum>/NN - Título.mp3`), da qual dá para gerar
**playlists M3U8** (geral e por cantor).

- Som de outros apps e do sistema **não** entra na gravação.
- Por padrão a gravação é **silenciosa** (nada sai nos alto-falantes); dá para
  ligar a monitoração com uma flag ou com a tecla `m` ao vivo.
- O volume do sistema (teclado/menu) **não** interfere no nível gravado — pode
  até deixar o Mac no mudo.

## Requisitos

- macOS 15+ (a API de process tap existe desde o macOS 14.4).
- Swift instalado (Xcode ou Command Line Tools).
- **ffmpeg** (`brew install ffmpeg`) — conversão MP3 e leitura de tags
  (ffprobe vem junto).
- Apple Music aberto (só para gravar; `playlist` funciona sem ele).

## Configuração obrigatória do Apple Music

Estes ajustes alteram o áudio **na origem** e precisam ficar neutros:

| Ajuste | Onde | Estado |
| --- | --- | --- |
| **Crossfade** (transição gradual) | Música → Ajustes → Reprodução | **Desligado** — senão o fim de uma faixa vaza no começo da outra |
| **Sound Check** (Verificação de Som) | Música → Ajustes → Reprodução | **Desligado** — altera o volume por faixa |
| **Equalizador** | Janela → Equalizador | **Desligado** |
| **Volume interno do app** (slider dentro do Music) | Janela principal do Music | **100%** — esse slider altera o stream gravado |

> O volume do **sistema** (teclas F11/F12, slider do menu) é aplicado depois do
> ponto de captura e não afeta a gravação. O slider **dentro do Music** afeta.

## Build

```sh
swift build -c release
```

Binário em `.build/release/AudioConvert`.

## Uso

O binário tem dois subcomandos: `record` (padrão — pode ser omitido) e
`playlist`.

### Gravar

```sh
# gravação padrão (mudo, saída em ./Recordings)
.build/release/AudioConvert

# escolher diretório de saída e/ou da biblioteca MP3
.build/release/AudioConvert --output ~/Music/Gravacoes --library ~/Music/Biblioteca

# ouvir nos alto-falantes desde o início
.build/release/AudioConvert --monitor
```

Depois é só dar play no Apple Music (arquivos locais). A cada troca de faixa o
gravador fecha o arquivo anterior, converte para ALAC, grava as tags (título,
artista, álbum) e o salva como `Artista - Título.m4a`. Em seguida converte para
MP3 320 (tags + capa embutidas) em
`<biblioteca>/<Álbum>/NN - Título.mp3`.

### Gerar playlists

```sh
# usa ./Recordings/Biblioteca
.build/release/AudioConvert playlist

# biblioteca em outro lugar
.build/release/AudioConvert playlist --library ~/Music/Biblioteca

# dupla com "&" que não deve ser dividida em dois cantores (repetível)
.build/release/AudioConvert playlist --keep "Roupa Nova & Amigos"
```

Escaneia os MP3s da biblioteca e escreve em `<Biblioteca>/Playlists/`:

- `Biblioteca.m3u8` — todas as faixas, ordenadas por álbum e número da faixa.
- `<Cantor>.m3u8` — uma playlist por cantor. Faixa com mais de um cantor na
  tag (ex.: `Anitta part. Ludmilla`) entra na playlist **de cada um**.

Regras de divisão da tag de artista:

- Dividem: `feat.`, `ft.`, `part.`, `participação`, vírgula, `;`, `/` e ` & `.
- ` & ` tem exceções: duplas conhecidas (Chitãozinho & Xororó, Sandy & Junior,
  Zezé Di Camargo & Luciano…) ficam juntas — estenda com `--keep`.
- ` e ` nunca divide (Jorge e Mateus é dupla, não dois cantores).

Rodar de novo regenera tudo: playlists de artistas que saíram da biblioteca
são removidas. Os caminhos dentro do `.m3u8` são relativos, então a pasta da
biblioteca pode ser movida inteira sem quebrar as playlists (VLC, Music,
foobar2000 abrem direto).

**Teclas durante a execução:**

| Tecla | Ação |
| --- | --- |
| `m` | Liga/desliga a saída nos alto-falantes (monitor) sem parar a gravação |
| `q` ou `Ctrl+C` | Encerra — finaliza a faixa corrente e as conversões antes de sair |

## Permissões (primeira execução)

1. **Gravação de áudio do sistema** — obrigatória. Sem ela o tap entrega
   **silêncio digital sem nenhum erro** (o app avisa no console após 5s de
   captura zerada).
   - Se aparecer o prompt de autorização, aceite.
   - **Se nenhum prompt aparecer** (comum na primeira vez): abra *Ajustes do
     Sistema → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema*,
     clique no botão **“+”**, adicione o app do terminal usado (Terminal,
     iTerm, VS Code…), ative a chave, **reinicie o terminal** e rode de novo.
2. **Automação (Apple Events)**: usada só para uma consulta inicial do estado
   do player via AppleScript. Se negar, o app funciona igual — só não detecta
   uma faixa que já estava tocando antes de ele subir.

## Gravação saiu muda?

Duas causas possíveis:

1. **Permissão ausente** — siga o passo do “+” acima. Confira se o terminal
   está listado **e ativado** no painel.
2. **Faixa de streaming da assinatura (DRM)** — o macOS zera a captura de
   conteúdo FairPlay; não é bug do app. Para conferir a origem da faixa:
   no Music, selecione a faixa → `Cmd+I` → aba **Arquivo**: arquivo local
   mostra “localização” com caminho no disco (ex.: `~/Music/...`); faixa de
   streaming não tem caminho. Grave apenas arquivos locais próprios.

Checagem rápida de nível do arquivo (com ffmpeg instalado):

```sh
ffmpeg -i "Recordings/arquivo.m4a" -af astats -f null - 2>&1 | grep "Peak level"
# Peak level dB: -inf  →  arquivo mudo
```

## Comportamento

- **Um `.m4a` ALAC (lossless) por faixa**, com tags embutidas, mais o **MP3
  320** correspondente na biblioteca por álbum (com capa, quando disponível).
- Faixa pulada/interrompida antes de ~90% da duração ganha sufixo ` (partial)`.
- **Pause não corta o arquivo** — ao retomar, a mesma faixa continua no mesmo
  arquivo.
- Nome de arquivo repetido ganha sufixo ` (2)`, ` (3)`…
- Caracteres inválidos em nomes (`/`, `:`) viram `-`.
- Arquivos temporários `.rec-*.caf` (ocultos) aparecem no diretório de saída
  durante a gravação e são apagados após a conversão. Se o app morrer no meio,
  o PCM cru fica lá e pode ser convertido manualmente com
  `afconvert -f m4af -d alac arquivo.caf saida.m4a`.

## Limitações conhecidas

- **Repetir 1 (repeat one)**: a mesma faixa tocando em sequência não gera
  fronteira detectável — as repetições caem num arquivo só.
- A notificação de troca chega alguns milissegundos depois do áudio; a
  fronteira entre faixas pode carregar um instante da faixa vizinha (com
  crossfade desligado, é silêncio).

## Nota legal

Ferramenta destinada a gravar **arquivos locais próprios** reproduzidos no
Apple Music. Faixas de streaming da assinatura são protegidas por DRM — não use
para capturar conteúdo que não é seu.
