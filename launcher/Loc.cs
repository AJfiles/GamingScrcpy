using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Windows;
using System.Windows.Markup;
using System.Windows.Data;

namespace GamingScrcpyLauncher
{
    // Localization layer. Every string the user can see lives in the table
    // below, in both languages, as one row per key: a row cannot exist for one
    // language only, which is the structural reason the gate does not have to
    // diff two dictionaries.
    //
    // XAML uses {loc:L Key}, which binds to the indexer below, so changing
    // Language raises PropertyChanged for every key and the whole UI --
    // labels, combo items, tooltips, status text, error dialogs and the command
    // preview -- relocalizes without restarting. Code-behind uses Loc.T("Key").
    public sealed class Loc : INotifyPropertyChanged
    {
        private const string Es = "es";
        private const string En = "en";

        public static readonly string[] Languages = { Es, En };

        // key, spanish, english
        private static readonly string[][] Table =
        {
            new[] { "AppTitle", "Gaming Scrcpy Launcher", "Gaming Scrcpy Launcher" },
            new[] { "AppSubtitle", "presentaci\u00f3n en el PC · resoluci\u00f3n del dispositivo intacta",
                    "host-side presentation \u00b7 device resolution untouched" },
            new[] { "LblLanguage", "Idioma", "Language" },
            new[] { "LangEs", "Español", "Español" },
            new[] { "LangEn", "English", "English" },
            new[] { "HintLanguage", "Cambia todo el texto al instante y se guarda en la configuraci\u00f3n",
                    "Switches every string immediately and is remembered" },
            new[] { "LblDevice", "Dispositivo:", "Device:" },
            new[] { "BadgeNoDevice", "sin dispositivo", "no device" },
            new[] { "BadgeDevices", "{0} dispositivo(s)", "{0} device(s)" },
            new[] { "SummaryNoDevice",
                    "conecta un tel\u00e9fono por USB o empareja uno por WiFi",
                    "connect a phone over USB, or pair one over WiFi" },
            new[] { "SummaryDevice",
                    "{0} \u00b7 {1} \u00b7 Android {2} (SDK {3})",
                    "{0} \u00b7 {1} \u00b7 Android {2} (SDK {3})" },
            // v3 §3: the shortcut list. The combination itself is never
            // translated, so only these two text cells exist per row.
            new[] { "ScCatMirror", "ESPEJO", "MIRROR" },
            new[] { "ScCatRecord", "GRABACI\u00d3N", "RECORDING" },
            new[] { "ScCatFilters", "FILTROS", "FILTERS" },
            new[] { "ScCatWindow", "VENTANA", "WINDOW" },
            new[] { "ScCatOther", "OTROS", "OTHER" },
            new[] { "ScWinTitle", "ATAJOS DE TECLADO", "KEYBOARD SHORTCUTS" },
            new[] { "ScWinNote",
                    "MOD es el modificador de scrcpy: Alt o Super (tecla Windows) por defecto, y se cambia con --shortcut-mod.",
                    "MOD is scrcpy's shortcut modifier: Alt or Super (Windows key) by default, changed with --shortcut-mod." },
            new[] { "ScWinClose", "CERRAR", "CLOSE" },
            new[] { "ScWinFooter",
                    "Cierra con el bot\u00f3n Cerrar. Los atajos act\u00faan sobre la ventana del espejo, no sobre el configurador.",
                    "Close it with the Close button. The shortcuts act on the mirror window, not on the configurator." },
            new[] { "ScActOsd", "Ciclo del OSD", "OSD cycle" },
            new[] { "ScDescOsd", "apagado, compacto y completo, en ese orden", "off, compact and full, in that order" },
            new[] { "ScActTouch", "Visualizador de tacto", "Touch visualizer" },
            new[] { "ScDescTouch", "anillos donde tocas, solo en la imagen del PC", "rings where you touch, on the PC picture only" },
            new[] { "ScActCursor", "Cursor visible u oculto", "Cursor shown or hidden" },
            new[] { "ScDescCursor", "si el rat\u00f3n del PC entra en el tel\u00e9fono", "whether the PC mouse reaches the phone" },
            new[] { "ScActScreenOff", "Apagar pantalla del tel\u00e9fono", "Turn the phone screen off" },
            new[] { "ScDescScreenOff", "el espejo y el audio siguen activos", "mirroring and audio keep running" },
            new[] { "ScActScreenOn", "Encender pantalla", "Turn the screen on" },
            new[] { "ScDescScreenOn", "sin tocar el bot\u00f3n f\u00edsico", "without the physical button" },
            new[] { "ScActRotateDevice", "Rotar pantalla del dispositivo", "Rotate the device screen" },
            new[] { "ScDescRotateDevice", "reordena el escritorio del tel\u00e9fono", "rearranges the phone's own layout" },
            new[] { "ScActHome", "HOME", "HOME" },
            new[] { "ScDescHome", "pantalla de inicio", "go home" },
            new[] { "ScActBack", "BACK", "BACK" },
            new[] { "ScDescBack", "atr\u00e1s", "back" },
            new[] { "ScActAppSwitch", "Cambiar de app", "App switch" },
            new[] { "ScDescAppSwitch", "vista de apps recientes", "recent apps view" },
            new[] { "ScActMenu", "MENU", "MENU" },
            new[] { "ScDescMenu", "desbloquea o abre el men\u00fa", "unlocks or opens the menu" },
            new[] { "ScActVolume", "Volumen del tel\u00e9fono", "Phone volume" },
            new[] { "ScDescVolume", "sube o baja el volumen del dispositivo", "up or down on the device" },
            new[] { "ScActPower", "Bot\u00f3n de encendido", "Power button" },
            new[] { "ScDescPower", "equivale a pulsarlo", "same as pressing it" },
            new[] { "ScActBorderless", "Pantalla completa sin bordes", "Borderless fullscreen" },
            new[] { "ScDescBorderless", "ocupa el \u00e1rea de trabajo; lee README \u00a77 si al arrancar no lo hace", "fills the work area; read README \u00a77 if startup does not" },
            new[] { "ScActOnTop", "Siempre encima", "Always on top" },
            new[] { "ScDescOnTop", "el espejo queda sobre tus aplicaciones", "the mirror stays over your apps" },
            new[] { "ScActFullscreen", "Pantalla completa", "Fullscreen" },
            new[] { "ScDescFullscreen", "la v\u00eda normal; F11 tambi\u00e9n vale", "the usual path; F11 works too" },
            new[] { "ScActFit", "Ventana 1:1", "Resize window 1:1" },
            new[] { "ScDescFit", "un p\u00edxel de pantalla por p\u00edxel de ventana", "one screen pixel per window pixel" },
            new[] { "ScActCrop", "Quitar bordes negros", "Remove black borders" },
            new[] { "ScDescCrop", "recorta la ventana a la imagen", "crops the window to the picture" },
            new[] { "ScActCollapse", "Cerrar paneles", "Collapse panels" },
            new[] { "ScDescCollapse", "notificaciones y ajustes", "notifications and settings" },
            new[] { "ScActQuit", "Cerrar scrcpy", "Quit scrcpy" },
            new[] { "ScDescQuit", "termina la sesi\u00f3n sin tocar el tel\u00e9fono", "ends the session, leaves the phone alone" },
            new[] { "ScActCopy", "Copiar al portapapeles del PC", "Copy to PC clipboard" },
            new[] { "ScDescCopy", "lee el portapapeles del tel\u00e9fono", "reads the phone clipboard" },
            new[] { "ScActPaste", "Sincronizar y pegar", "Synchronize and paste" },
            new[] { "ScDescPaste", "iguala ambos portapapeles", "makes both clipboards match" },
            new[] { "ScActInject", "Inyectar texto del PC", "Inject computer clipboard" },
            new[] { "ScDescInject", "escribe lo del PC sin pegar", "sends the PC text without pasting" },
            new[] { "ScActFps", "Contador de FPS", "FPS counter" },
            new[] { "ScDescFps", "se imprime en la consola, no en la ventana", "prints to the console, not on screen" },
            new[] { "ScActPause", "Pausar v\u00eddeo", "Pause video" },
            new[] { "ScDescPause", "deja de llegar imagen; el audio sigue", "the picture stops, audio continues" },
            new[] { "ScActUnpause", "Reanudar v\u00eddeo", "Resume video" },
            new[] { "ScDescUnpause", "los frames vuelven a llegar", "frames start arriving again" },
            new[] { "ScActResetEncoder", "Reiniciar c\u00f3dec", "Reset encoder" },
            new[] { "ScDescResetEncoder", "\u00fatil si el tel\u00e9fono bloquea su codificador", "useful when the phone refuses its encoder" },
            new[] { "ScActNotifications", "Notificaciones", "Notification panel" },
            new[] { "ScDescNotifications", "desliza el panel desde el PC", "pulls the panel from the PC" },
            new[] { "AudioUnsupported",
                    "Audio del dispositivo: NO SOPORTADO (requiere Android 11+)",
                    "Device audio: NOT SUPPORTED (needs Android 11+)" },
            new[] { "AudioSupported",
                    "Audio del dispositivo: compatible (Android 11+)",
                    "Device audio: supported (Android 11+)" },
            new[] { "BtnAudioDiag", "Diagn\u00f3stico de audio", "Audio diagnostic" },
            new[] { "HintAudioDiag",
                    "Comprueba SDK, soporte, el mensaje del servidor, la salida del PC y el volumen del tel\u00e9fono. Solo lectura.",
                    "Checks the SDK, support, the server message, the PC sink and the phone volume. Read-only." },
            new[] { "TipAudioNeedsApi30",
                    "Tel\u00e9fono anterior a Android 11: scrcpy no puede capturar su audio",
                    "Phone older than Android 11: scrcpy cannot capture its audio" },
            new[] { "TipAudioEnabled",
                    "Opciones de captura del audio del tel\u00e9fono",
                    "Phone audio capture options" },
            new[] { "DiagAudioNoDevice",
                    "Diagn\u00f3stico de audio: no hay tel\u00e9fono conectado",
                    "Audio diagnostic: no phone connected" },
            new[] { "DiagAudioSdk",
                    "Diagn\u00f3stico de audio \u00b7 {0} \u00b7 SDK {1} \u00b7 Android {2}",
                    "Audio diagnostic \u00b7 {0} \u00b7 SDK {1} \u00b7 Android {2}" },
            new[] { "DiagAudioYes",
                    "Soporte: s\u00ed, este tel\u00e9fono puede enviar su audio",
                    "Support: yes, this phone can send its audio" },
            new[] { "DiagAudioNo",
                    "Soporte: NO. Hace falta Android 11 (API 30); el launcher env\u00eda --no-audio",
                    "Support: NO. Android 11 (API 30) is required; the launcher sends --no-audio" },
            new[] { "DiagAudioServer",
                    "Mensaje del servidor: {0}",
                    "Server message: {0}" },
            new[] { "DiagAudioNoLine",
                    "a\u00fan no hay ninguna l\u00ednea de audio en el registro (inicia una sesi\u00f3n)",
                    "no audio line in the log yet (start a session)" },
            new[] { "DiagAudioSink", "Salida de audio del PC: {0}", "PC audio sink: {0}" },
            new[] { "DiagAudioIdle", "sin sesi\u00f3n activa", "no session running" },
            new[] { "DiagAudioNoAudioFlag",
                    "desactivada por el launcher (--no-audio)",
                    "disabled by the launcher (--no-audio)" },
            new[] { "DiagAudioMuted",
                    "enmudecida hacia el PC (--no-audio-playback, solo el tap PCM)",
                    "muted to the PC (--no-audio-playback, PCM tap only)" },
            new[] { "DiagAudioPlaying",
                    "sonando en el PC (revisa scrcpy en el mezclador de volumen)",
                    "playing on the PC (check scrcpy in the volume mixer)" },
            new[] { "DiagAudioVolume",
                    "Volumen del tel\u00e9fono (solo lectura): {0}",
                    "Phone volume (read-only): {0}" },
            new[] { "DiagAudioNoVolume",
                    "dumpsys audio no devolvi\u00f3 niveles legibles",
                    "dumpsys audio returned no readable levels" },
            new[] { "BtnRescan", "Reescanear ADB", "Rescan ADB" },
            new[] { "BtnWireless", "Gu\u00eda ADB inal\u00e1mbrico", "Wireless ADB guide" },
            new[] { "WirelessGuideTitle", "ADB inal\u00e1mbrico: pasos manuales",
                    "Wireless ADB: manual steps" },
            new[] { "WirelessGuideBody",
                    "Este launcher no pone el dispositivo en modo TCP: eso escribe "
                    + "en el propio tablet, y el proyecto lo mantiene de solo lectura.\n\n"
                    + "H\u00e1zalo t\u00fa una vez (README_GAMING.md, secci\u00f3n 7) y luego usa "
                    + "\u00abEmparejar\u00bb o \u00abConectar ip:puerto\u00bb, que no tocan nada del "
                    + "dispositivo.",
                    "This launcher does not switch the device to TCP mode: that writes "
                    + "to the tablet itself, and this project keeps it read-only.\n\n"
                    + "Do it once by hand (README_GAMING.md, section 7), then use "
                    + "\u00abPair wireless\u00bb or \u00abConnect ip:port\u00bb, which never write to "
                    + "the device." },
            new[] { "WirelessGuideLogged",
                    "gu\u00eda de ADB inal\u00e1mbrico: README_GAMING.md \u00a77",
                    "wireless ADB guide: README_GAMING.md \u00a77" },
            new[] { "BtnPair", "Emparejar inal\u00e1mbrico", "Pair wireless" },
            new[] { "BtnConnect", "Conectar ip:puerto", "Connect ip:port" },

            new[] { "SecOneClick", "LANZAR EN UN CLIC", "ONE-CLICK LAUNCH" },
            new[] { "BtnMirror", "Espejo (latencia m\u00ednima)", "Mirror (low latency)" },
            new[] { "BtnMirrorRecord", "Espejo + grabaci\u00f3n autom\u00e1tica",
                    "Mirror + auto-record" },
            new[] { "BtnRecordOnly", "Solo grabar (sin ventana)", "Record only (no window)" },
            new[] { "BtnStop", "Detener", "Stop" },
            new[] { "HintShortcuts",
                    "Atajos en la ventana del espejo: Super/Alt+F1 cambia el OSD, F2 pantalla completa sin bordes, F3 visualizador de tacto, F4 cursor, F5 siempre encima, F10 captura PNG.",
                    "Shortcuts in the mirror window: Super/Alt+F1 cycles the OSD, F2 borderless fullscreen, F3 touch visualizer, F4 cursor, F5 always-on-top, F10 screenshot." },

            new[] { "SecProfiles", "PERFILES", "PROFILES" },
            new[] { "BtnLoad", "Cargar", "Load" },
            new[] { "BtnSaveAs", "Guardar como\u2026", "Save as\u2026" },
            new[] { "BtnNew", "Nuevo", "New" },
            new[] { "BtnDelete", "Borrar", "Delete" },
            new[] { "BtnExportJson", "Exportar JSON", "Export JSON" },
            new[] { "BtnImportJson", "Importar JSON", "Import JSON" },
            new[] { "HintProfileName", "Nombre del perfil", "Profile name" },

            new[] { "SecKeymap", "TECLADO / MANDO", "KEYMAP / CONTROLLER" },
            new[] { "BtnApplyKeymap", "Aplicar mapa", "Apply keymap" },
            new[] { "BtnOpenKeymapDir", "Abrir carpeta", "Open folder" },
            new[] { "HintKeymapDetails", "Detalles del mapa seleccionado",
                    "Details of the selected keymap" },

            new[] { "TabQuick", "R\u00e1pido", "Quick" },
            new[] { "TabCapture", "Captura", "Capture" },
            new[] { "TabPresentation", "Presentaci\u00f3n", "Presentation" },
            new[] { "TabFilters", "Filtros", "Filters" },
            new[] { "TabRecorder", "Grabaci\u00f3n / OBS", "Recording / OBS" },
            new[] { "TabControl", "Control", "Control" },
            new[] { "TabAdvanced", "Avanzado", "Advanced" },
            new[] { "TabPerf", "Rendimiento", "Performance" },
            new[] { "HintAdvanced", "Agrupado aqu\u00ed para que la vista normal tenga 3-5 controles; nada se ha eliminado",
                    "Kept here so the default view shows 3-5 controls; nothing was removed" },

            new[] { "SecCapture", "CAPTURA (encoder del dispositivo · framebuffer intacto)",
                     "CAPTURE (device encoder \u00b7 framebuffer untouched)" },
            new[] { "LblVideoCodec", "Codec de v\u00eddeo", "Video codec" },
            new[] { "LblAudioCodec", "Codec de audio", "Audio codec" },
            new[] { "LblBitrate", "Bits (Mbps)", "Bitrate (Mbps)" },
            new[] { "LblMaxFps", "FPS m\u00e1x.", "Max FPS" },
            new[] { "LblAudioBitrate", "Bits de audio (kbps)", "Audio bitrate (kbps)" },
            new[] { "LblHwdec", "Decodificaci\u00f3n HW", "Hardware decode" },
            new[] { "NoteDeviceHw", "HW del dispositivo", "device HW" },
            new[] { "ItemHevc", "hevc (H.265)", "hevc (H.265)" },
            new[] { "ItemHwAuto", "auto", "auto" },
            new[] { "ItemHwOff", "desactivada (por software)", "disabled (software decoding)" },
            new[] { "ItemHwD3d", "d3d11va (forzada)", "d3d11va (forced)" },

            new[] { "SecHost", "PRESENTACI\u00d3N EN EL PC", "HOST PRESENTATION (PC SIDE)" },
            new[] { "LblRenderer", "Renderizador", "Renderer" },
            new[] { "LblUpscale", "Filtro de escalado", "Upscale filter" },
            new[] { "LblWindowKernel", "Kernel de ventana", "Window kernel" },
            new[] { "LblHostTarget", "Tama\u00f1o objetivo", "Host target size" },
            new[] { "LblFitMode", "Modo de ajuste", "Fit mode" },
            new[] { "LblVideoBuffer", "B\u00fader de v\u00eddeo (ms)", "Video buffer (ms)" },
            new[] { "LblAudioBuffer", "B\u00fader de audio (ms)", "Audio out buffer (ms)" },
            new[] { "LblEncoderPreset", "Preset del encoder", "Encoder preset" },
            new[] { "ItemRendererDefault", "por defecto (elige SDL)", "default (SDL picks)" },
            new[] { "ItemUpscaleLinear", "lineal (suave)", "linear (smooth)" },
            new[] { "ItemUpscalePixel", "pixelart (adaptativo, retro)", "pixelart (adaptive, retro games)" },
            new[] { "ItemUpscaleNearest", "nearest (p\u00edxeles 1:1)", "nearest (1:1 pixels)" },
            new[] { "ItemUpscaleDefault", "por defecto", "default" },
            new[] { "ItemWinOff", "apagado (la GPU estira la imagen)", "off (GPU stretches the picture)" },
            new[] { "ItemWinLanczos", "lanczos (kernel real, ~2,5 ms/fotograma)",
                    "lanczos (true kernel, ~2.5ms/frame)" },
            new[] { "ItemWinFast", "r\u00e1pido (bilineal, barato)", "fast (bilinear, cheapest)" },
            new[] { "ItemWinPoint", "point (sin interpolaci\u00f3n)", "point (no interpolation)" },
            new[] { "ItemFitAspect", "ajustar ventana a la proporci\u00f3n", "fit window to device aspect" },
            new[] { "ItemFitPortrait1080", "1080x1920 vertical", "1080x1920 portrait" },
            new[] { "ItemFitPortrait1440", "1440x2560 vertical", "1440x2560 portrait" },
            new[] { "NoteCpu", "CPU", "CPU" },

            new[] { "ChkLowLatency", "Latencia m\u00ednima (sin vsync)", "Low latency (no vsync)" },
            new[] { "ChkBorderless", "Pantalla completa sin bordes", "Borderless fullscreen" },
            new[] { "ChkOnTop", "Siempre encima", "Always on top" },
            new[] { "ChkMipmaps", "Mipmaps", "Mipmaps" },
            new[] { "ChkTouchViz", "Visualizador de tacto", "Touch visualizer" },
            new[] { "LblOsd", "Telemetr\u00eda OSD", "OSD telemetry" },
            new[] { "LblCursorHide", "Ocultar cursor (ms)", "Cursor auto-hide (ms)" },
            new[] { "ItemOsdFull", "completo (fps, bits, latencia)", "full (fps, bitrate, latency)" },
            new[] { "ItemOsdCompact", "compacto (fps, latencia)", "compact (fps, latency)" },
            new[] { "ItemOsdNone", "ninguno", "none" },

            new[] { "SecFilters", "FILTROS DE IMAGEN (host)", "IMAGE FILTERS (HOST SIDE)" },
            new[] { "SecFilterPanel", "PANEL DE FILTROS EN TIEMPO REAL",
                    "REAL-TIME FILTER PANEL" },
            new[] { "ChkFilterPanel", "Panel flotante sobre el mirror",
                    "Floating panel over the mirror" },
            new[] { "TipFilterPanel",
                    "Ventana propia, siempre encima: mueve el color del "
                    + "espejo sin tocar el pipeline del frame. Medido: la "
                    + "mediana por frame no cambia con el panel abierto.",
                    "Its own always-on-top window: it changes the mirror's "
                    + "colour without touching the frame pipeline. Measured: "
                    + "the median per-frame cost does not move with the panel "
                    + "open." },
            new[] { "LblOverlayHotkey", "Atajo global", "Global hotkey" },
            new[] { "TipOverlayHotkey",
                    "Modificador+tecla separados por +, por ejemplo "
                    + "super+alt+f. Evita super/alt+F1 a F5, que ya son "
                    + "atajos del espejo. Si otra app tiene esa combinación, "
                    + "el panel se abre con la misma tecla mientras el "
                    + "espejo tenga el foco.",
                    "Modifiers and one key joined by +, e.g. super+alt+f. "
                    + "Avoid super/alt+F1 to F5, already mirror shortcuts. "
                    + "If another app owns the combination, the same key "
                    + "still opens the panel while the mirror has focus." },
            new[] { "ChkOverlayVisible", "Abrirlo al empezar la sesión",
                    "Open it when the session starts" },
            new[] { "TipOverlayVisible",
                    "Sin marcar, el panel espera al atajo global.",
                    "Unmarked, the panel waits for the global hotkey." },
            new[] { "NoteOverlayHotkey",
                    "Esa combinación no es válida: se necesita al menos un "
                    + "modificador (ctrl, alt, shift, super) y una sola tecla "
                    + "(f1 a f9, una letra o un número). Se usará super+alt+f.",
                    "That combination is not valid: it needs at least one "
                    + "modifier (ctrl, alt, shift, super) and exactly one key "
                    + "(f1 to f9, a letter or a digit). super+alt+f will be "
                    + "used instead." },
            new[] { "NoteOverlayProfiles",
                    "Los grados con nombre se guardan en "
                    + "%APPDATA%\\GamingScrcpy\\filters.profiles, se aplican "
                    + "al empezar y se guardan con el perfil de sesión.",
                    "Named grades live in %APPDATA%\\GamingScrcpy\\"
                    + "filters.profiles, are applied at session start and "
                    + "travel with the session profile." },
            new[] { "ScActFilterPanel", "Panel de filtros",
                    "Filter panel" },
            new[] { "ScDescFilterPanel",
                    "Abre o cierra el panel flotante de filtros en vivo",
                    "Shows or hides the floating live filter panel" },
            new[] { "ScActClosePanel", "Cerrar el panel", "Close the panel" },
            new[] { "ScDescClosePanel",
                    "Cierra el panel de filtros sin cambiar el grado activo",
                    "Closes the filter panel without changing the active "
                    + "grade" },
            new[] { "LblContrast", "Contraste %", "Contrast %" },
            new[] { "LblBrightness", "Brillo %", "Brightness %" },
            new[] { "LblGamma", "Gamma %", "Gamma %" },
            new[] { "LblSaturation", "Saturaci\u00f3n %", "Saturation %" },
            new[] { "LblSharpness", "Nitidez %", "Sharpness %" },
            new[] { "LblNightBoost", "Levante de sombras %", "Shadow lift %" },
            new[] { "BtnResetFilter", "reset", "reset" },
            new[] { "BtnNeutral", "Neutral", "Neutral" },
            new[] { "BtnVivid", "Vivid", "Vivid" },
            new[] { "BtnCinematic", "Cinematic", "Cinematic" },
            new[] { "BtnNight", "Night", "Night" },

            new[] { "SecBridge", "GRABADOR / PUENTE DE STREAM", "RECORDER / STREAM BRIDGE" },
            new[] { "LblContainer", "Contenedor", "Container" },
            new[] { "LblRecordFile", "Archivo de grabaci\u00f3n", "Record file" },
            new[] { "LblFrameBridge", "Puente de frames", "Frame bridge" },
            new[] { "LblBridgeScale", "Escala del puente", "Bridge scale" },
            new[] { "LblBridgeKernel", "Kernel del puente", "Bridge kernel" },
            new[] { "LblAudioBridge", "Puente de audio", "Audio bridge" },
            new[] { "LblPcmTap", "Toma PCM", "PCM tap" },
            new[] { "ChkMutePc", "silenciar PC", "mute PC" },
            new[] { "LblExtraArgs", "Args extra scrcpy/ADB", "Extra scrcpy/ADB args" },
            new[] { "TipFrameBridge", @"\\.\pipe\gaming-frame, una ruta o -",
                    @"\\.\pipe\gaming-frame, a file path or -" },
            new[] { "TipBridgeScale", "Tama\u00f1o exacto de salida del puente, p. ej. 1920x1080. Vac\u00edo = tama\u00f1o del dispositivo",
                    "Exact output size for the bridged feed, e.g. 1920x1080. Empty keeps the device size" },
            new[] { "TipAudioBridge", "Paquetes codificados (opus/aac/raw). Vale para un segundo grabador, no para un cable virtual",
                    "Encoded packets (opus/aac/raw). Good for a second recorder, useless for a virtual cable" },
            new[] { "TipPcmTap", @"Audio decodificado s16le / 48 kHz / estéreo: lo que espera un cable virtual o ffmpeg -f s16le, p. ej. \\.\pipe\gaming-pcm",
                    @"Decoded audio as s16le / 48 kHz / stereo: what a virtual cable or ffmpeg -f s16le expects, e.g. \\.\pipe\gaming-pcm" },
            new[] { "TipMutePc", "Env\u00eda el audio solo a la toma PCM (--no-audio-playback): OBS oye el cable, tus altavoces callan",
                    "Send the game audio only to the PCM tap (--no-audio-playback): OBS hears the cable, your speakers stay quiet" },
            new[] { "TipMouseBindings",
                    "4 caracteres para clic derecho/medio/4.\u00ba/5.\u00ba: + adelante, - ignora, b atr\u00e1s, h home, s cambiar app, n panel. Opcional tras ':' para Shift+clic, p. ej. nbsh:++++",
                    "4 chars for right/middle/4th/5th click: + forward, - ignore, b back, h home, s app switch, n notify panel. Optional second sequence after ':' for Shift+click, e.g. nbsh:++++" },
            new[] { "HintBridge",
                    "El puente de frames escribe RGBA crudos en su propio hilo con cola descarta-el-m\u00e1s-viejo: un OBS/FFmpeg lento no puede frenar el espejo. La escala del puente remuestrea ese flujo (lanczos/bicubic) a un tama\u00f1o exacto como 1920x1080 sin tocar el framebuffer del dispositivo ni la ventana.",
                    "The frame bridge writes raw RGBA on its own thread with a drop-oldest queue: a slow OBS/FFmpeg consumer can never stall the mirror. A bridge scale resamples that feed (Lanczos/bicubic) to an exact size such as 1920x1080 without touching the device framebuffer or the mirrored window." },
            new[] { "BtnCopyObs", "OBS: copiar comando ffplay", "OBS: copy ffplay command" },
            new[] { "BtnCopyCommand", "Copiar l\u00ednea de comandos", "Copy command line" },

            new[] { "SecControl", "CONTROL", "CONTROL" },
            new[] { "LblKeyboard", "Teclado", "Keyboard" },
            new[] { "LblMouse", "Rat\u00f3n", "Mouse" },
            new[] { "LblGamepad", "Mando", "Gamepad" },
            new[] { "LblMouseBindings", "Atajos de rat\u00f3n", "Mouse bindings" },
            new[] { "ItemAutoDefault", "auto (por defecto de scrcpy)", "auto (scrcpy default)" },
            new[] { "ItemUhidMouse", "uhid (captura de rat\u00f3n / punter\u00eda FPS)", "uhid (mouse capture / FPS aim)" },
            new[] { "ItemAoa", "aoa", "aoa" },
            new[] { "ItemDisabled", "desactivado", "disabled" },
            new[] { "ItemUhidAdb", "uhid (sobre ADB)", "uhid (over ADB)" },
            new[] { "ItemAoaUsb", "aoa (requiere USB AOA)", "aoa (needs USB AOA)" },

            new[] { "SecPerf", "RENDIMIENTO EN VIVO (telemetr\u00eda del fork)",
                    "LIVE PERFORMANCE (fork telemetry)" },
            new[] { "LblLiveLatency", "Latencia med. (ms)", "Median latency (ms)" },
            new[] { "LblLiveFps", "FPS", "FPS" },
            new[] { "LblLiveBitrate", "Video (KB/s)", "Video (KB/s)" },
            new[] { "LblLiveAudio", "Audio (KB/s)", "Audio (KB/s)" },
            new[] { "HintPerf", "Alimentado por --game-telemetry-log del proceso hijo; 1 Hz",
                    "Fed by the child process --game-telemetry-log; 1 Hz" },
            new[] { "PerfWaiting", "esperando telemetr\u00eda\u2026", "waiting for telemetry\u2026" },

            new[] { "SecDevicePanel", "DISPOSITIVO", "DEVICE" },
            new[] { "LblBattery", "Bater\u00eda", "Battery" },
            new[] { "LblTemperature", "Temperatura", "Temperature" },
            new[] { "LblModel", "Modelo", "Model" },
            new[] { "HintDevicePanel", "solo lectura, v\u00eda adb shell dumpsys", "read-only, via adb shell dumpsys" },

            new[] { "LblCommand", "COMANDO", "COMMAND" },
            new[] { "LblRunLog", "REGISTRO", "RUN LOG" },
            new[] { "StatusIdle", "Inactivo", "Idle" },
            new[] { "LblScrcpy", "scrcpy:", "scrcpy:" },
            new[] { "LblAdb", "adb:", "adb:" },
            new[] { "ValNotSet", "(sin definir)", "(not set)" },
            new[] { "ValNotFound", "(no encontrado)", "(not found)" },

            new[] { "StatusNoDevice", "No hay dispositivo ADB conectado", "No ADB device connected" },
            new[] { "StatusStarted", "Iniciado (pid {0})", "Started (pid {0})" },
            new[] { "StatusStopped", "Detenido", "Stopped" },
            new[] { "StatusRescanned", "{0} dispositivo(s) tras reescanear", "{0} device(s) after rescan" },
            new[] { "StatusSaved", "Perfil guardado: {0}", "Profile saved: {0}" },
            new[] { "StatusDeleted", "Perfil borrado: {0}", "Profile deleted: {0}" },
            new[] { "StatusLoaded", "Perfil cargado: {0}", "Profile loaded: {0}" },
            new[] { "StatusKeymap", "Mapa aplicado: {0}", "Keymap applied: {0}" },
            new[] { "StatusCopied", "Comando copiado al portapapeles", "Command copied to the clipboard" },
            new[] { "StatusLangChanged", "Idioma: {0}", "Language: {0}" },
            new[] { "StatusExported", "Perfiles exportados a {0}", "Profiles exported to {0}" },
            new[] { "StatusImported", "Perfiles importados desde {0}", "Profiles imported from {0}" },
            new[] { "StatusTcpIp", "TCP/IP activado en {0}", "TCP/IP enabled on {0}" },
            new[] { "StatusPaired", "Emparejado con {0}", "Paired with {0}" },
            new[] { "StatusConnected", "Conectado {0}", "Connected {0}" },
            new[] { "StatusBattery", "Bater\u00eda {0}% · {1}\u00b0C", "Battery {0}% \u00b7 {1} C" },

            new[] { "ErrStartFailed", "No se pudo iniciar scrcpy: {0}", "Could not start scrcpy: {0}" },
            new[] { "ErrNoScrcpy", "Falta scrcpy.exe: config\u00falo con --set-scrcpy o en la variable de entorno SCRCPY",
                    "scrcpy.exe not found: set it with --set-scrcpy or the SCRCPY environment variable" },
            new[] { "ErrNoAdb", "No se encuentra adb.exe junto al launcher ni en el PATH", "adb.exe was found neither next to the launcher nor on PATH" },
            new[] { "ErrProfileName", "Necesitas un nombre de perfil", "A profile name is required" },
            new[] { "ErrDelete", "Selecciona un perfil para borrarlo", "Select a profile to delete" },
            new[] { "ErrBusy", "Ya hay una sesi\u00f3n en curso; det\u00e9n antes de cambiar esto",
                    "A session is already running; stop it before changing this" },
            new[] { "ErrBadValue", "Valor no v\u00e1lido: {0}", "Invalid value: {0}" },
            new[] { "ErrUnsupported", "Este valor no lo acepta el binario real: {0}",
                    "The real binary rejects this value: {0}" },
            new[] { "AskDeleteProfile", "\u00bfBorrar el perfil {0}?", "Delete profile {0}?" },
            new[] { "AskTitle", "Gaming Scrcpy Launcher", "Gaming Scrcpy Launcher" },
            new[] { "BtnOk", "Aceptar", "OK" },
            new[] { "BtnCancel", "Cancelar", "Cancel" },

            new[] { "SecShortcuts", "ATAJOS", "SHORTCUTS" },
            new[] { "HintShortcutsOverlay", "Pulsa F1 aqu\u00ed o en la ventana del espejo para ver los atajos",
                    "Press F1 here or in the mirror window to list the shortcuts" },

            // ---- runtime messages (log panel, status, dialogs) ----
            // nothing user-visible may be built in the code-behind: the log
            // panel and the dialogs are part of the UI as much as a label is.
            new[] { "AppName", "Gaming Scrcpy", "Gaming Scrcpy" },
            new[] { "ConfirmTitle", "Confirmar", "Confirm" },
            new[] { "LogScanning", "escaneando dispositivos adb", "scanning adb devices" },
            new[] { "LogDetected", "detectado: {0} estado={1}", "detected: {0} state={1}" },
            new[] { "LogAutoScanStopped",
                    "auto-reescaneo detenido: {0} (usa Reescanear ADB)",
                    "auto-rescan stopped: {0} (use Rescan ADB)" },
            new[] { "LogDeviceModel", "modelo del dispositivo: {0}", "device model: {0}" },
            new[] { "LogAv1Fallback",
                    "AV1 no existe en SDK {0}: se ha cambiado a h264 para que "
                    + "la sesi\u00f3n arranque",
                    "no AV1 encoder on SDK {0}: switched to h264 so the session "
                    + "can start" },
            new[] { "LogNoDevice",
                    "no se detect\u00f3 ning\u00fan dispositivo adb "
                    + "(conecta por USB o empareja por Wi-Fi)",
                    "no adb device found (connect by USB, or pair wirelessly)" },
            new[] { "LogPair", "emparejamiento inal\u00e1mbrico -> {0}", "wireless pair -> {0}" },
            new[] { "LogConnect", "conexi\u00f3n inal\u00e1mbrica -> {0}", "wireless connect -> {0}" },
            new[] { "LogAlreadyRunning",
                    "ya se est\u00e1 ejecutando - detenlo primero",
                    "already running - stop it first" },
            new[] { "LogLaunch", "lanzando: {0}", "launching: {0}" },
            new[] { "LogStartFailed",
                    "no se pudo iniciar scrcpy: {0}", "failed to start scrcpy: {0}" },
            new[] { "LogStartFailedPlain",
                    "no se pudo iniciar scrcpy", "failed to start scrcpy" },
            new[] { "StatusRecording", "grabando", "recording" },
            new[] { "StatusMirroring", "espejando", "mirroring" },
            new[] { "StatusStoppedExit", "detenido (salida {0})", "stopped (exit {0})" },
            new[] { "LogExitCode",
                    "scrcpy termin\u00f3 con c\u00f3digo {0}", "scrcpy exited with code {0}" },
            new[] { "LogRecordingKept",
                    "grabaci\u00f3n conservada: {0} ({1} bytes)",
                    "recording kept: {0} ({1} bytes)" },
            new[] { "LogStopRequested", "paro solicitado", "stop requested" },
            new[] { "LogProfileLoaded",
                    "perfil cargado: {0}", "loaded profile {0}" },
            new[] { "LogProfileSaved", "perfil guardado: {0}", "saved profile {0}" },
            new[] { "ProfileNew", "Perfil nuevo", "New profile" },
            new[] { "LogNewProfile",
                    "perfil nuevo iniciado (gu\u00e1rdalo cuando est\u00e9 listo)",
                    "new profile started (Save it when ready)" },
            new[] { "ConfirmDeleteProfile",
                    "\u00bfEliminar el perfil {0}?", "Delete profile {0}?" },
            new[] { "LogDeleted", "eliminado: {0}", "deleted {0}" },
            new[] { "LogKeymapBad",
                    "el keymap no se ha podido analizar", "keymap could not be parsed" },
            new[] { "LogKeymapApplied",
                    "keymap aplicado: {0} (teclado={1} rat\u00f3n={2} mando={3})",
                    "applied keymap {0} (keyboard={1} mouse={2} gamepad={3})" },
            new[] { "LogBridgeResample",
                    "el puente de v\u00eddeo reescalar\u00e1 a {0} en su propio hilo",
                    "frame bridge will resample to {0} on its own thread" },
            new[] { "LogCopiedCommand",
                    "l\u00ednea de comandos copiada al portapapeles",
                    "command line copied to clipboard" },
            new[] { "LogCopiedObs",
                    "recetas de OBS / FFmpeg copiadas al portapapeles",
                    "OBS / FFmpeg consumer commands copied to clipboard" },
            new[] { "DlgNoDeviceBody",
                    "Ning\u00fan dispositivo seleccionado. Conecta un tel\u00e9fono "
                    + "(con depuraci\u00f3n USB activada) o empareja uno por Wi-Fi antes.",
                    "No device selected. Connect a phone (USB debugging enabled) or "
                    + "pair one over Wi-Fi first." },
            new[] { "DlgNoExeBody",
                    "No se encuentra scrcpy.exe. Coloca GamingScrcpyLauncher.exe "
                    + "junto al paquete de scrcpy, o escribe "
                    + "{{\"scrcpy\": \"C:\\\\path\\\\scrcpy.exe\"}} en {0}.",
                    "scrcpy.exe not found. Put GamingScrcpyLauncher.exe next to the "
                    + "scrcpy package, or write "
                    + "{{\"scrcpy\": \"C:\\\\path\\\\scrcpy.exe\"}} into {0}." },
            new[] { "NoteAv1", "necesita codificador AV1", "needs AV1 encoder" },
            new[] { "NoteHevc", "necesita codificador HEVC", "needs HEVC encoder" },

            // ---- discrete numeric steps + encoder preset ----
            new[] { "LblEncoder", "Preset del codificador", "Encoder preset" },
            new[] { "TipEncoderPreset",
                    "Se traduce a la clave latency de MediaFormat "
                    + "(--video-codec-options=latency:N): m\u00e1s alta = menos "
                    + "tiempo por cuadro, menos calidad por bit. El codificador "
                    + "del dispositivo puede ignorarla.",
                    "Maps to the MediaFormat latency key "
                    + "(--video-codec-options=latency:N): higher means less time "
                    + "per frame and less quality per bit. The device encoder may "
                    + "ignore it." },
            new[] { "ItemEncoderDefault", "el del dispositivo", "device default" },
            new[] { "ItemEncoderUltrafast", "ultrafast (latencia 9)",
                    "ultrafast (latency 9)" },
            new[] { "ItemEncoderFast", "fast (latencia 7)", "fast (latency 7)" },
            new[] { "ItemEncoderMedium", "medium (latencia 5)", "medium (latency 5)" },
            new[] { "NoteMediaCodec", "MediaFormat", "MediaFormat" },
            new[] { "UnitMbps", "{0} Mb/s", "{0} Mb/s" },
            new[] { "UnitFps", "{0} fps", "{0} fps" },
            new[] { "UnitKbps", "{0} kbps", "{0} kbps" },
            new[] { "UnitMs", "{0} ms", "{0} ms" },
        };

        // static on purpose: the table is filled while the singleton below is
        // still being constructed, so nothing in it may go through Instance.
        // It must also stay declared BEFORE Instance: static initializers run in
        // textual order, and the constructor already writes into this map.
        private static readonly Dictionary<string, string> current =
            new Dictionary<string, string>(StringComparer.Ordinal);

        public static readonly Loc Instance = new Loc();

        private readonly Dictionary<string, int> esIndex = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly Dictionary<string, int> enIndex = new Dictionary<string, int>(StringComparer.Ordinal);

        public event PropertyChangedEventHandler? PropertyChanged;

        private string language = En;

        private Loc()
        {
            for (int i = 0; i < Table.Length; ++i)
            {
                esIndex[Table[i][0]] = i;
                enIndex[Table[i][0]] = i;
            }
            // assign directly: the Language setter ignores a no-op change and the
            // field already defaults to En, which left the table empty
            language = En;
            Rebuild();
        }

        public static string[] Keys
        {
            get
            {
                var keys = new string[Table.Length];
                for (int i = 0; i < Table.Length; ++i)
                {
                    keys[i] = Table[i][0];
                }
                return keys;
            }
        }

        public string Language
        {
            get => language;
            set
            {
                string want = value == Es ? Es : En;
                if (language == want)
                {
                    return;
                }
                language = want;
                Rebuild();
            }
        }

        public static string LanguageName(string code) =>
            code == Es ? "Espa\u00f1ol" : "English";

        private void Rebuild()
        {
            var map = language == Es ? esIndex : enIndex;
            foreach (var pair in map)
            {
                string value = Table[pair.Value][language == Es ? 1 : 2];
                // an empty translation must be loud: the UI Automation audit
                // fails on "???", so a missing column cannot ship as an
                // English label inside a Spanish panel
                current[pair.Key] = string.IsNullOrEmpty(value) ? "??? " + pair.Key : value;
            }
            ApplyResources();
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item"));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        }

        // The XAML reads every string through {DynamicResource Key}, so pushing
        // the whole table into the application resources is what makes the
        // switch hot: labels, combo items, tooltips and the window title all
        // re-resolve the moment the values are replaced.
        public static void ApplyResources()
        {
            var app = System.Windows.Application.Current;
            if (app == null)
            {
                return;
            }
            foreach (string key in Keys)
            {
                app.Resources[key] = Get(key);
            }
        }

        // Called from a field initializer in MainWindow, i.e. before
        // InitializeComponent, so the very first paint already has strings.
        public static object Bootstrap()
        {
            ApplyResources();
            return new object();
        }

        public string this[string key] => Get(key);

        public static string Get(string key)
        {
            if (current.TryGetValue(key, out string? text))
            {
                return text;
            }
            // A missing key must be loud: the gate fails on it, and a release
            // build that lost a row shows the key instead of a blank UI.
            return "???" + key;
        }

        public static string T(string key) => Get(key);

        public static string Format(string key, params object[] args) =>
            string.Format(Get(key), args);
    }
}

