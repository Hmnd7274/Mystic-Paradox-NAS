// Dedicated client-side Rams -> Platinum menu. Included by dllmain.cpp after the runtime helpers.
#pragma once

#include <winhttp.h>
#pragma comment(lib, "winhttp.lib")

namespace RamsToPlatinumMenu {

static constexpr int kAmounts[] = { 100, 500, 1000, 5000 };
static constexpr size_t kLineCount = 9;

struct HttpReply {
    DWORD status = 0;
    std::string body;
    std::string error;
};

static std::mutex s_sessionMutex;
static std::wstring s_playerBearer;
static std::mutex s_stateMutex;
static std::atomic<bool> s_requestInFlight{ false };
static std::atomic<bool> s_open{ false };
static std::atomic<bool> s_quoteReady{ false };
static int64_t s_rams = 0;
static int64_t s_platinum = 0;
static int s_rate = 15;
static int s_selected = 0;
static std::atomic<uint64_t> s_retryAtMs{ 0 };
static uint64_t s_lastTickMs = 0;
static std::wstring s_status = L"Connexion au serveur...";
static SDK::UUserWidget* s_widget = nullptr;
static SDK::UTextBlock* s_lines[kLineCount]{};
static std::wstring s_lastLineText[kLineCount];
static SDK::APlayerController* s_menuController = nullptr;
static bool s_previousMouseCursor = false;
static SHORT s_keyF8 = 0;
static SHORT s_keyEscape = 0;
static SHORT s_keyUp = 0;
static SHORT s_keyDown = 0;
static SHORT s_keyEnter = 0;
static thread_local bool s_inClientTick = false;

static bool Call(SDK::UObject* Object, const char* ClassName, const char* FunctionName, void* Params) {
    if (!Object || !Object->Class) return false;
    SDK::UFunction* Function = Object->Class->GetFunction(ClassName, FunctionName);
    if (!Function) return false;
    Object->ProcessEvent(Function, Params);
    return true;
}

static bool IsGameForeground() {
    const HWND Foreground = GetForegroundWindow();
    if (!Foreground) return false;
    DWORD ProcessId = 0;
    GetWindowThreadProcessId(Foreground, &ProcessId);
    return ProcessId == GetCurrentProcessId();
}

static bool KeyPressed(int VirtualKey, SHORT& Previous) {
    const SHORT Current = GetAsyncKeyState(VirtualKey);
    const bool Pressed = (Current & 0x8000) != 0 && (Previous & 0x8000) == 0;
    Previous = Current;
    return Pressed;
}

static std::wstring FormatNumber(int64_t Value) {
    std::wstring Digits = std::to_wstring(Value);
    std::wstring Formatted;
    Formatted.reserve(Digits.size() + Digits.size() / 3);
    for (size_t Index = 0; Index < Digits.size(); ++Index) {
        if (Index != 0 && (Digits.size() - Index) % 3 == 0) Formatted += L' ';
        Formatted += Digits[Index];
    }
    return Formatted;
}

static const uint8_t* FTextFor(const std::wstring& Value) {
    static std::unordered_map<std::wstring, const uint8_t*> s_cache;
    const auto Existing = s_cache.find(Value);
    if (Existing != s_cache.end()) return Existing->second;

    struct {
        const wchar_t* Data;
        int32_t Num;
        int32_t Max;
        uint8_t ReturnValue[0x18];
    } Convert{};
    static_assert(sizeof(Convert) == 0x28, "Kismet StringToText parameters must be 0x28 bytes");
    Convert.Data = Value.c_str();
    Convert.Num = Convert.Max = static_cast<int32_t>(Value.size()) + 1;
    if (!Call(SDK::UKismetTextLibrary::GetDefaultObj(), "KismetTextLibrary", "Conv_StringToText", &Convert)) {
        return nullptr;
    }

    auto* Stored = new uint8_t[0x18];
    memcpy(Stored, Convert.ReturnValue, 0x18);
    s_cache.emplace(Value, Stored);
    return Stored;
}

static void SetLine(size_t Index, const std::wstring& Value) {
    if (Index >= kLineCount || !s_lines[Index] || s_lastLineText[Index] == Value) return;
    const uint8_t* Text = FTextFor(Value);
    if (!Text) return;
    struct { uint8_t InText[0x18]; } Params{};
    memcpy(Params.InText, Text, sizeof(Params.InText));
    if (Call(s_lines[Index], "TextBlock", "SetText", &Params)) s_lastLineText[Index] = Value;
}

static SDK::UObject* SpawnWidgetObject(SDK::UClass* Class, SDK::UObject* Outer) {
    if (!Class || !Outer) return nullptr;
    struct { SDK::UClass* ObjectClass; SDK::UObject* Outer; SDK::UObject* ReturnValue; } Params{ Class, Outer, nullptr };
    Call(SDK::UGameplayStatics::GetDefaultObj(), "GameplayStatics", "SpawnObject", &Params);
    return Params.ReturnValue;
}

static SDK::UTextBlock* NewText(SDK::UWidgetTree* Tree, int FontSize) {
    auto* Text = static_cast<SDK::UTextBlock*>(SpawnWidgetObject(SDK::UTextBlock::StaticClass(), Tree));
    if (!Text) return nullptr;
    Text->Font.Size = FontSize;
    Text->Justification = SDK::ETextJustify::Center;
    return Text;
}

static void AddTextLine(SDK::UVerticalBox* Box, SDK::UWidgetTree* Tree, size_t Index, int FontSize,
                        const std::wstring& InitialText) {
    if (!Box || !Tree || Index >= kLineCount) return;
    SDK::UTextBlock* Text = NewText(Tree, FontSize);
    if (!Text) return;
    Box->AddChildToVerticalBox(Text);
    s_lines[Index] = Text;
    SetLine(Index, InitialText);
}

static bool BuildWidget(SDK::APlayerController* PlayerController) {
    if (!PlayerController || !IsRegisteredLiveObject(PlayerController)) return false;
    auto* Widget = SDK::UWidgetBlueprintLibrary::Create(
        PlayerController, SDK::UUserWidget::StaticClass(), PlayerController);
    if (!Widget || !Widget->WidgetTree) {
        MpLog("[RamsToPlatinum] could not create the UUserWidget / WidgetTree");
        return false;
    }

    SDK::UWidgetTree* Tree = Widget->WidgetTree;
    auto* Canvas = static_cast<SDK::UCanvasPanel*>(SpawnWidgetObject(SDK::UCanvasPanel::StaticClass(), Tree));
    auto* Panel = static_cast<SDK::UBorder*>(SpawnWidgetObject(SDK::UBorder::StaticClass(), Tree));
    auto* Stack = static_cast<SDK::UVerticalBox*>(SpawnWidgetObject(SDK::UVerticalBox::StaticClass(), Tree));
    if (!Canvas || !Panel || !Stack) {
        MpLog("[RamsToPlatinum] could not create the native UMG controls");
        return false;
    }

    Tree->RootWidget = Canvas;
    SDK::FLinearColor Background{};
    Background.R = 0.018f;
    Background.G = 0.024f;
    Background.B = 0.038f;
    Background.A = 0.96f;
    Panel->SetBrushColor(Background);
    SDK::FMargin PanelPadding{};
    PanelPadding.Left = 22.0f;
    PanelPadding.Top = 18.0f;
    PanelPadding.Right = 22.0f;
    PanelPadding.Bottom = 18.0f;
    Panel->SetPadding(PanelPadding);
    Panel->SetContent(Stack);

    auto* CanvasSlot = Canvas->AddChildToCanvas(Panel);
    if (!CanvasSlot) return false;
    SDK::FAnchors Anchors{};
    Anchors.Minimum.X = 0.5f;
    Anchors.Minimum.Y = 0.5f;
    Anchors.Maximum.X = 0.5f;
    Anchors.Maximum.Y = 0.5f;
    CanvasSlot->SetAnchors(Anchors);
    CanvasSlot->SetAlignment(SDK::FVector2D{ 0.5f, 0.5f });
    CanvasSlot->SetPosition(SDK::FVector2D{ -360.0f, -225.0f });
    CanvasSlot->SetSize(SDK::FVector2D{ 720.0f, 450.0f });

    s_lines[0] = nullptr;
    s_lines[1] = nullptr;
    s_lines[2] = nullptr;
    s_lines[3] = nullptr;
    s_lines[4] = nullptr;
    s_lines[5] = nullptr;
    s_lines[6] = nullptr;
    s_lines[7] = nullptr;
    s_lines[8] = nullptr;
    for (std::wstring& Last : s_lastLineText) Last.clear();

    AddTextLine(Stack, Tree, 0, 26, L"ECHANGE RAMS  ->  PLATINUM");
    AddTextLine(Stack, Tree, 1, 18, L"Chargement du solde...");
    AddTextLine(Stack, Tree, 2, 17, L"Taux : 15 Rams pour 1 Platinum");
    AddTextLine(Stack, Tree, 3, 19, L"");
    AddTextLine(Stack, Tree, 4, 19, L"");
    AddTextLine(Stack, Tree, 5, 19, L"");
    AddTextLine(Stack, Tree, 6, 19, L"");
    AddTextLine(Stack, Tree, 7, 17, L"Connexion au serveur...");
    AddTextLine(Stack, Tree, 8, 15, L"Haut/Bas : choisir   |   Entree : convertir   |   Echap/F8 : fermer");

    Widget->bIsFocusable = true;
    Widget->AddToViewport(900);
    s_widget = Widget;
    s_menuController = PlayerController;
    s_previousMouseCursor = PlayerController->bShowMouseCursor;
    PlayerController->bShowMouseCursor = false;

    struct { SDK::APlayerController* Target; SDK::UWidget* InWidgetToFocus; bool bLockMouseToViewport; uint8_t Pad[7]; }
        InputMode{ PlayerController, Widget, true, {} };
    Call(SDK::UWidgetBlueprintLibrary::GetDefaultObj(), "WidgetBlueprintLibrary", "SetInputMode_UIOnly", &InputMode);

    MpLog("[RamsToPlatinum] F8 menu opened");
    return true;
}

static void CloseWidget() {
    if (s_widget && IsRegisteredLiveObject(s_widget)) s_widget->RemoveFromParent();
    if (s_menuController && IsRegisteredLiveObject(s_menuController)
        && s_menuController->IsA(SDK::APlayerController::StaticClass())) {
        s_menuController->bShowMouseCursor = s_previousMouseCursor;
        struct { SDK::APlayerController* PlayerController; } InputMode{ s_menuController };
        Call(SDK::UWidgetBlueprintLibrary::GetDefaultObj(), "WidgetBlueprintLibrary", "SetInputMode_GameOnly", &InputMode);
    }
    s_widget = nullptr;
    s_menuController = nullptr;
    for (size_t Index = 0; Index < kLineCount; ++Index) s_lines[Index] = nullptr;
    s_open.store(false, std::memory_order_release);
    MpLog("[RamsToPlatinum] menu closed");
}

static int64_t ReadJsonInteger(const std::string& Json, const char* Key, int64_t Fallback) {
    const std::string Needle = std::string("\"") + Key + "\"";
    size_t Position = Json.find(Needle);
    if (Position == std::string::npos) return Fallback;
    Position = Json.find(':', Position + Needle.size());
    if (Position == std::string::npos) return Fallback;
    ++Position;
    while (Position < Json.size() && (Json[Position] == ' ' || Json[Position] == '\t')) ++Position;
    size_t End = Position;
    if (End < Json.size() && Json[End] == '-') ++End;
    while (End < Json.size() && Json[End] >= '0' && Json[End] <= '9') ++End;
    if (End == Position || (Json[Position] == '-' && End == Position + 1)) return Fallback;
    try { return std::stoll(Json.substr(Position, End - Position)); } catch (...) { return Fallback; }
}

static HttpReply SendBackendRequest(const std::wstring& Bearer, const wchar_t* Path, const std::string& Body) {
    HttpReply Reply;
    const wchar_t* ApiBase = MpApiBase();
    if (!ApiBase || !*ApiBase) {
        Reply.error = "backend address unavailable";
        return Reply;
    }

    std::wstring FullUrl(ApiBase);
    FullUrl += Path;
    URL_COMPONENTS Components{};
    Components.dwStructSize = sizeof(Components);
    Components.dwSchemeLength = static_cast<DWORD>(-1);
    Components.dwHostNameLength = static_cast<DWORD>(-1);
    Components.dwUrlPathLength = static_cast<DWORD>(-1);
    Components.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(FullUrl.c_str(), static_cast<DWORD>(FullUrl.size()), 0, &Components)) {
        Reply.error = "invalid backend URL";
        return Reply;
    }

    const std::wstring Host(Components.lpszHostName, Components.dwHostNameLength);
    const std::wstring UrlPath(Components.lpszUrlPath, Components.dwUrlPathLength);
    HINTERNET Session = WinHttpOpen(L"MysticParadox-RamsToPlatinum/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!Session) { Reply.error = "WinHttpOpen failed"; return Reply; }
    WinHttpSetTimeouts(Session, 3000, 3000, 4000, 4000);

    HINTERNET Connection = WinHttpConnect(Session, Host.c_str(), Components.nPort, 0);
    if (!Connection) {
        Reply.error = "WinHttpConnect failed";
        WinHttpCloseHandle(Session);
        return Reply;
    }

    const bool Secure = Components.nScheme == INTERNET_SCHEME_HTTPS;
    HINTERNET Request = WinHttpOpenRequest(Connection, Body.empty() ? L"GET" : L"POST",
        UrlPath.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
        Secure ? WINHTTP_FLAG_SECURE : 0);
    if (!Request) {
        Reply.error = "WinHttpOpenRequest failed";
        WinHttpCloseHandle(Connection);
        WinHttpCloseHandle(Session);
        return Reply;
    }

    std::wstring Headers = L"Authorization: " + Bearer + L"\r\n";
    if (!Body.empty()) Headers += L"Content-Type: application/json\r\n";
    const LPVOID Data = Body.empty() ? WINHTTP_NO_REQUEST_DATA : const_cast<char*>(Body.data());
    const DWORD DataLength = static_cast<DWORD>(Body.size());
    const BOOL Sent = WinHttpSendRequest(Request, Headers.c_str(), static_cast<DWORD>(-1),
        Data, DataLength, DataLength, 0);
    if (!Sent || !WinHttpReceiveResponse(Request, nullptr)) {
        Reply.error = "backend request failed";
        WinHttpCloseHandle(Request);
        WinHttpCloseHandle(Connection);
        WinHttpCloseHandle(Session);
        return Reply;
    }

    DWORD Status = 0;
    DWORD StatusSize = sizeof(Status);
    if (WinHttpQueryHeaders(Request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &Status, &StatusSize, WINHTTP_NO_HEADER_INDEX)) {
        Reply.status = Status;
    }

    for (;;) {
        DWORD Available = 0;
        if (!WinHttpQueryDataAvailable(Request, &Available) || Available == 0) break;
        if (Reply.body.size() + Available > 32768) {
            Reply.error = "backend response too large";
            Reply.body.clear();
            break;
        }
        std::vector<char> Buffer(Available);
        DWORD Read = 0;
        if (!WinHttpReadData(Request, Buffer.data(), Available, &Read) || Read == 0) break;
        Reply.body.append(Buffer.data(), Read);
    }

    WinHttpCloseHandle(Request);
    WinHttpCloseHandle(Connection);
    WinHttpCloseHandle(Session);
    return Reply;
}

static bool ReadPlayerBearerFromRequest(void* Request, std::wstring& Out) {
    if (!Request || !IsReadablePointer(Request, 0xD0)) return false;
    void** Vtable = *reinterpret_cast<void***>(Request);
    if (!Vtable || !IsReadablePointer(Vtable, 17 * sizeof(void*))) return false;

    struct RawFString { wchar_t* Data; int32_t Num; int32_t Max; };
    FString HeaderName(L"Authorization");
    RawFString Existing{};
    using GetHeaderFn = void*(*)(void*, void*, const void*);
    reinterpret_cast<GetHeaderFn>(Vtable[2])(Request, &Existing, &HeaderName);

    bool Valid = false;
    if (Existing.Data && Existing.Num > 8 && Existing.Num <= 8192
        && Existing.Max >= Existing.Num
        && IsReadablePointer(Existing.Data, static_cast<size_t>(Existing.Num) * sizeof(wchar_t))) {
        Out.assign(Existing.Data, static_cast<size_t>(Existing.Num - 1));
        Valid = Out.size() > 7 && _wcsnicmp(Out.c_str(), L"Bearer ", 7) == 0;
    }
    MpEngineFree(Existing.Data);
    if (!Valid) Out.clear();
    return Valid;
}

static void SetStatus(const std::wstring& Value) {
    std::lock_guard<std::mutex> Lock(s_stateMutex);
    s_status = Value;
}

static bool GetBearer(std::wstring& Out) {
    std::lock_guard<std::mutex> Lock(s_sessionMutex);
    Out = s_playerBearer;
    return !Out.empty();
}

static bool GenerateRequestId(std::string& Out) {
    unsigned char Bytes[16]{};
    if (!SystemFunction036(Bytes, static_cast<ULONG>(sizeof(Bytes)))) return false;
    static const char Hex[] = "0123456789abcdef";
    Out.clear();
    Out.reserve(32);
    for (unsigned char Byte : Bytes) {
        Out += Hex[Byte >> 4];
        Out += Hex[Byte & 0x0F];
    }
    return true;
}

static void RefreshQuoteAsync() {
    bool Expected = false;
    if (!s_requestInFlight.compare_exchange_strong(Expected, true, std::memory_order_acq_rel)) return;
    std::wstring Bearer;
    if (!GetBearer(Bearer)) {
        s_requestInFlight.store(false, std::memory_order_release);
        SetStatus(L"En attente de la session joueur...");
        s_retryAtMs.store(GetTickCount64() + 1500, std::memory_order_release);
        return;
    }

    SetStatus(L"Lecture du solde...");
    std::thread([Bearer]() {
        HttpReply Reply = SendBackendRequest(Bearer, L"/rams-to-platinum", "");
        std::lock_guard<std::mutex> Lock(s_stateMutex);
        if (Reply.status == 200 && Reply.error.empty()) {
            s_rate = static_cast<int>(ReadJsonInteger(Reply.body, "rate", 15));
            s_rams = ReadJsonInteger(Reply.body, "rams", 0);
            s_platinum = ReadJsonInteger(Reply.body, "platinum", 0);
            s_quoteReady.store(true, std::memory_order_release);
            s_status = L"Choisissez un montant puis appuyez sur Entree.";
        } else {
            s_quoteReady.store(false, std::memory_order_release);
            s_status = Reply.status == 403 ? L"Session joueur refusee (403)."
                : L"Impossible de lire le solde. Reessayez.";
        }
        s_retryAtMs.store(GetTickCount64() + 3000, std::memory_order_release);
        s_requestInFlight.store(false, std::memory_order_release);
    }).detach();
}

static void ConvertSelectedAsync() {
    bool Expected = false;
    if (!s_requestInFlight.compare_exchange_strong(Expected, true, std::memory_order_acq_rel)) return;
    std::wstring Bearer;
    if (!GetBearer(Bearer)) {
        s_requestInFlight.store(false, std::memory_order_release);
        SetStatus(L"Session joueur introuvable.");
        return;
    }
    std::string RequestId;
    if (!GenerateRequestId(RequestId)) {
        s_requestInFlight.store(false, std::memory_order_release);
        SetStatus(L"Impossible de generer une cle de transaction.");
        return;
    }

    const int Amount = kAmounts[s_selected];
    const std::string Body = std::string("{\"platinumAmount\":")
        + std::to_string(Amount) + ",\"requestId\":\"" + RequestId + "\"}";
    SetStatus(L"Conversion en cours...");
    std::thread([Bearer, Amount, Body]() {
        HttpReply Reply = SendBackendRequest(Bearer, L"/rams-to-platinum/convert", Body);
        std::lock_guard<std::mutex> Lock(s_stateMutex);
        if (Reply.status == 200 && Reply.error.empty()) {
            s_rams = ReadJsonInteger(Reply.body, "rams", s_rams);
            s_platinum = ReadJsonInteger(Reply.body, "platinum", s_platinum);
            s_status = L"Conversion effectuee : +" + std::to_wstring(Amount) + L" Platinum.";
            s_quoteReady.store(true, std::memory_order_release);
        } else if (Reply.status == 402) {
            s_status = L"Solde Rams insuffisant.";
        } else if (Reply.status == 403) {
            s_status = L"Session joueur refusee. Reconnectez-vous.";
        } else if (Reply.status == 409) {
            s_status = L"Transaction en conflit. Actualisez le menu.";
        } else {
            s_status = L"Echec de conversion. Verifiez le serveur.";
        }
        s_retryAtMs.store(GetTickCount64() + 2500, std::memory_order_release);
        s_requestInFlight.store(false, std::memory_order_release);
    }).detach();
}

static void RefreshWidgetText() {
    if (!s_widget || !IsRegisteredLiveObject(s_widget)) return;
    int Rate = 15;
    int64_t Rams = 0;
    int64_t Platinum = 0;
    std::wstring Status;
    {
        std::lock_guard<std::mutex> Lock(s_stateMutex);
        Rate = s_rate;
        Rams = s_rams;
        Platinum = s_platinum;
        Status = s_status;
    }
    SetLine(1, L"Solde : " + FormatNumber(Rams) + L" Rams     |     " + FormatNumber(Platinum) + L" Platinum");
    SetLine(2, L"Taux : " + std::to_wstring(Rate) + L" Rams = 1 Platinum");
    for (int Index = 0; Index < 4; ++Index) {
        const int PlatinumAmount = kAmounts[Index];
        const int64_t RamsCost = static_cast<int64_t>(PlatinumAmount) * Rate;
        const std::wstring Prefix = Index == s_selected ? L"> " : L"  ";
        const std::wstring Label = Prefix + std::to_wstring(Index + 1) + L". " + FormatNumber(RamsCost)
            + L" Rams  ->  " + FormatNumber(PlatinumAmount) + L" Platinum";
        SetLine(3 + Index, Label);
    }
    SetLine(7, Status);
}

static bool IsOpen() {
    return s_open.load(std::memory_order_acquire);
}

static void OpenMenu() {
    SDK::APlayerController* PlayerController = static_cast<SDK::APlayerController*>(s_LastPossessedPC);
    if (!PlayerController || !IsRegisteredLiveObject(PlayerController)
        || !PlayerController->IsA(SDK::APlayerController::StaticClass())) {
        MpLog("[RamsToPlatinum] F8 ignored: no live local PlayerController");
        return;
    }
    if (!BuildWidget(PlayerController)) return;
    s_selected = 0;
    s_quoteReady.store(false, std::memory_order_release);
    s_retryAtMs = 0;
    s_open.store(true, std::memory_order_release);
    RefreshWidgetText();
}

static void OnClientHttpRequest(void* Request) {
    if (Globals::AmServer || MpProcessDetaching()) return;
    std::wstring Bearer;
    if (!ReadPlayerBearerFromRequest(Request, Bearer)) return;
    std::lock_guard<std::mutex> Lock(s_sessionMutex);
    s_playerBearer = std::move(Bearer);
}

static void OnClientProcessEvent() {
    if (Globals::AmServer || MpProcessDetaching() || s_inClientTick) return;
    const uint64_t Now = GetTickCount64();
    if (Now - s_lastTickMs < 40) return;
    s_lastTickMs = Now;
    s_inClientTick = true;

    const bool GameForeground = IsGameForeground();
    if (GameForeground && KeyPressed(VK_F8, s_keyF8)) {
        if (IsOpen()) CloseWidget();
        else OpenMenu();
    }

    if (!IsOpen()) {
        s_inClientTick = false;
        return;
    }

    if (GameForeground && KeyPressed(VK_ESCAPE, s_keyEscape)) {
        CloseWidget();
        s_inClientTick = false;
        return;
    }
    if (GameForeground && KeyPressed(VK_UP, s_keyUp)) s_selected = (s_selected + 3) % 4;
    if (GameForeground && KeyPressed(VK_DOWN, s_keyDown)) s_selected = (s_selected + 1) % 4;
    if (GameForeground && KeyPressed(VK_RETURN, s_keyEnter)) {
        if (s_quoteReady.load(std::memory_order_acquire)) ConvertSelectedAsync();
        else SetStatus(L"Attendez le chargement du solde.");
    }

    if (!s_quoteReady.load(std::memory_order_acquire)
        && !s_requestInFlight.load(std::memory_order_acquire)
        && Now >= s_retryAtMs.load(std::memory_order_acquire)) {
        RefreshQuoteAsync();
    }

    RefreshWidgetText();
    s_inClientTick = false;
}

}  // namespace RamsToPlatinumMenu
