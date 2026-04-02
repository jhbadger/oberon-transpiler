/*
 * Oberon IDE — Turbo Pascal 7-style IDE built on magiblot/tvision
 *
 */

#define Uses_TApplication
#define Uses_TButton
#define Uses_TDeskTop
#define Uses_TDialog
#define Uses_TEditor
#define Uses_TEvent
#define Uses_TFileDialog
#define Uses_TFileEditor
#define Uses_TFrame
#define Uses_TIndicator
#define Uses_TInputLine
#define Uses_TKeys
#define Uses_TLabel
#define Uses_TCheckBoxes
#define Uses_TSItem
#define Uses_TMenuBar
#define Uses_TMenuItem
#define Uses_TProgram
#define Uses_TRect
#define Uses_TScrollBar
#define Uses_TStaticText
#define Uses_TStatusDef
#define Uses_TStatusItem
#define Uses_TStatusLine
#define Uses_TSubMenu
#define Uses_TWindow
#define Uses_MsgBox
#define Uses_TTerminal
#define Uses_otstream
#define Uses_TDrawBuffer
#define Uses_TScroller
#define Uses_TScreen
#define Uses_TFindDialogRec
#define Uses_TReplaceDialogRec
#define Uses_TEditorDialog
#define Uses_TColorAttr
#include <tvision/tv.h>

#include <cstring>
#include <cstdarg>
#include <cstdio>
#include <string>
#include <vector>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>

// Custom commands — all above 200 to avoid clashing with tvision built-ins
const ushort
    cmNewFile     = 201,
    cmOpenFile    = 202,
    cmSaveFile    = 203,
    cmSaveFileAs  = 204,
    cmRunProgram  = 205,
    cmAbout       = 206,
    cmGotoLine    = 207,
    cmCompileOnly = 208,     // F8: compile without running
    cmWindowList  = 209,     // Show window list dialog
    cmWindow1     = 210,     // cmWindow1..cmWindow1+N select window N
                             // (reserve 210-249 for up to 40 windows)
    cmCloseWindow = 250;     // Ctrl-W: close active editor window

// ── Run oberon  ────────────────────────────────────────────────
struct RunResult { int errorLine; std::string errorText; };

static RunResult runOberon(const char* filepath, bool runAfter = true) {
    // 1. Prepare Paths
    std::string sourcePath = filepath;
    std::string exePath = sourcePath;

    // Strip ".mod" to get the executable name
    size_t lastDot = exePath.find_last_of(".");
    if (lastDot != std::string::npos) {
        exePath = exePath.substr(0, lastDot);
    }

    // Ensure we run from the current directory if no path is provided
    std::string runCmd = exePath;
    if (runCmd.find('/') == std::string::npos) {
        runCmd = "./" + runCmd;
    }

    // 2. Suspend UI
    TScreen::suspend();
    printf("\n--- %s: %s ---\n", runAfter ? "Compiling" : "Compile check", filepath);
    fflush(stdout);

    // 3. Build the Shell Command
    std::string compilerBin = "obc";
    std::string fullCmd = runAfter
        ? compilerBin + " " + sourcePath + " && " + runCmd
        : compilerBin + " " + sourcePath;

    int errpipe[2];
    pipe(errpipe);

    pid_t pid = fork();
    if (pid == 0) {
        close(errpipe[0]);
        dup2(errpipe[1], STDERR_FILENO); // Capture compiler errors and runtime crashes
        close(errpipe[1]);

        execlp("sh", "sh", "-c", fullCmd.c_str(), nullptr);
        _exit(127);
    } else if (pid > 0) {
        close(errpipe[1]);
        std::string errout;
        char ebuf[1024];
        ssize_t n;
        while ((n = read(errpipe[0], ebuf, sizeof(ebuf))) > 0)
            errout.append(ebuf, n);
        close(errpipe[0]);

        int status = 0;
        waitpid(pid, &status, 0);
        bool failed = !(WIFEXITED(status) && WEXITSTATUS(status) == 0);

        if (failed) {
            // Parse "filename:LINE:col: error:" format emitted by the compiler
            auto parseErrorLine = [](const std::string& s) -> int {
                size_t p = 0;
                while (p < s.size()) {
                    // Find a colon followed by digits followed by another colon
                    size_t c = s.find(':', p);
                    if (c == std::string::npos) break;
                    size_t numStart = c + 1;
                    if (numStart < s.size() && isdigit((unsigned char)s[numStart])) {
                        size_t numEnd = numStart;
                        while (numEnd < s.size() && isdigit((unsigned char)s[numEnd])) numEnd++;
                        if (numEnd < s.size() && s[numEnd] == ':')
                            return std::stoi(s.substr(numStart, numEnd - numStart));
                    }
                    p = c + 1;
                }
                return 0;
            };

            int errorLine = parseErrorLine(errout);
            printf("\n--- Error — press Enter to return ---");
            fflush(stdout);
            while (getchar() != '\n');
            TScreen::resume();
            TProgram::application->redraw();
            return { errorLine, errout };
        }
    }

    // 4. Success Completion
    printf("\n\n[Process completed] - Press Enter");
    fflush(stdout);
    while (getchar() != '\n');

    TScreen::resume();
    TProgram::application->redraw();
    return { 0, "" };
}

// ── Output dialog ─────────────────────────────────────────────────────────
class TOutputDialog : public TDialog {
public:
    TOutputDialog(const std::string& text, bool success)
        : TWindowInit(&TOutputDialog::initFrame),
          TDialog(TRect(2, 1, 78, 22),
                  success ? " Program Output " : " Output / Errors ")
    {
        options |= ofCentered;
        TScrollBar* vbar = new TScrollBar(TRect(size.x-2, 1,        size.x-1, size.y-3));
        TScrollBar* hbar = new TScrollBar(TRect(1,        size.y-3, size.x-2, size.y-2));
        insert(vbar);
        insert(hbar);
        TRect r(1, 1, size.x-2, size.y-3);
        auto* term = new TTerminal(r, hbar, vbar, 32768);
        insert(term);
        otstream os(term);
        os << text;
        if (text.empty() || text.back() != '\n') os << '\n';
        os.flush();
        insert(new TButton(TRect((size.x-10)/2, size.y-2, (size.x+10)/2, size.y-1),
                           "  ~O~K  ", cmOK, bfDefault));
        selectNext(False);
    }
};

// ── editorDialog implementation ───────────────────────────────────────────
static ushort oberonEditorDialog(int dialog, ...) {
    va_list args;
    va_start(args, dialog);
    ushort result = cmCancel;

    switch (dialog) {
        case edFind: {
            TFindDialogRec* rec = va_arg(args, TFindDialogRec*);
            TDialog* dlg = new TDialog(TRect(0,0,50,10), " Find ");
            dlg->options |= ofCentered;
            TInputLine* findInp = new TInputLine(TRect(2,3,48,4), maxFindStrLen);
            dlg->insert(new TLabel(TRect(2,2,12,3), "~T~ext:", findInp));
            dlg->insert(findInp);
            TCheckBoxes* opts = new TCheckBoxes(TRect(2,5,48,7),
                new TSItem("~C~ase sensitive",
                new TSItem("~W~hole words only", nullptr)));
            dlg->insert(opts);
            dlg->insert(new TButton(TRect(12,8,22,9), " ~O~K ",     cmOK,     bfDefault));
            dlg->insert(new TButton(TRect(28,8,38,9), " ~C~ancel ", cmCancel, bfNormal));
            findInp->setData((void*)rec->find);
            ushort optVal = rec->options & (efCaseSensitive | efWholeWordsOnly);
            opts->setData(&optVal);
            dlg->selectNext(False);
            if (TProgram::deskTop->execView(dlg) != cmCancel) {
                findInp->getData(rec->find);
                opts->getData(&optVal);
                rec->options = (rec->options & ~(efCaseSensitive|efWholeWordsOnly)) | optVal;
                result = cmOK;
            }
            TObject::destroy(dlg);
            break;
        }
        case edReplace: {
            TReplaceDialogRec* rec = va_arg(args, TReplaceDialogRec*);
            TDialog* dlg = new TDialog(TRect(0,0,54,14), " Replace ");
            dlg->options |= ofCentered;
            TInputLine* findInp = new TInputLine(TRect(2,3,52,4), maxFindStrLen);
            dlg->insert(new TLabel(TRect(2,2,14,3), "~F~ind:", findInp));
            dlg->insert(findInp);
            TInputLine* replInp = new TInputLine(TRect(2,6,52,7), maxReplaceStrLen);
            dlg->insert(new TLabel(TRect(2,5,20,6), "~R~eplace with:", replInp));
            dlg->insert(replInp);
            TCheckBoxes* opts = new TCheckBoxes(TRect(2,8,52,11),
                new TSItem("~C~ase sensitive",
                new TSItem("~W~hole words only",
                new TSItem("~P~rompt on replace",
                new TSItem("~A~ll occurrences", nullptr)))));
            dlg->insert(opts);
            dlg->insert(new TButton(TRect(8,12,20,13),  " ~O~K ",     cmOK,     bfDefault));
            dlg->insert(new TButton(TRect(24,12,38,13), " ~C~ancel ", cmCancel, bfNormal));
            findInp->setData((void*)rec->find);
            replInp->setData((void*)rec->replace);
            ushort optVal = rec->options &
                (efCaseSensitive|efWholeWordsOnly|efPromptOnReplace|efReplaceAll);
            opts->setData(&optVal);
            dlg->selectNext(False);
            if (TProgram::deskTop->execView(dlg) != cmCancel) {
                findInp->getData(rec->find);
                replInp->getData(rec->replace);
                opts->getData(&optVal);
                rec->options = (rec->options &
                    ~(efCaseSensitive|efWholeWordsOnly|efPromptOnReplace|efReplaceAll)) | optVal;
                result = cmOK;
            }
            TObject::destroy(dlg);
            break;
        }
        case edReplacePrompt:
            result = messageBox(" Replace this occurrence? ", mfYesNoCancel | mfInformation);
            break;
        case edSearchFailed:
            messageBox(" Search string not found. ", mfOKButton | mfInformation);
            result = cmOK;
            break;
        case edOutOfMemory:
            messageBox(" Not enough memory for this operation. ", mfOKButton | mfError);
            result = cmOK;
            break;
        case edSaveModify: {
            const char* fname = va_arg(args, const char*);
            char msg[128];
            snprintf(msg, sizeof(msg), " %s has been modified. Save? ", fname ? fname : "File");
            result = messageBox(msg, mfYesNoCancel | mfInformation);
            break;
        }
        case edSaveAs: {
            const char* fname = va_arg(args, const char*);
            TFileDialog* dlg = new TFileDialog("*.mod", " Save As ", "~N~ame", fdOKButton, 100);
            result = cmCancel;
            if (TProgram::deskTop->execView(dlg) != cmCancel) {
                char buf[MAXPATH] = {};
                dlg->getFileName(buf);
                if (fname) strncpy(const_cast<char*>(fname), buf, MAXPATH-1);
                result = cmOK;
            }
            TObject::destroy(dlg);
            break;
        }
        default:
            result = cmCancel;
            break;
    }
    va_end(args);
    return result;
}

static const char* OBERON_KEYWORDS[] = {
	"ARRAY", "BEGIN", "BY", "CASE", "CONST", "DIV", "DO", "ELSE",
	"ELSIF", "END", "FALSE", "FOR", "IF", "IMPORT", "IN", "IS",
	"MOD", "MODULE", "NIL", "OF", "OR", "POINTER", "PROCEDURE",
	"RECORD", "REPEAT", "RETURN", "THEN", "TO", "TRUE", "TYPE",
	"UNTIL", "VAR", "WHILE", "BOOLEAN", "BYTE", "CHAR", "INTEGER",
	"REAL", "SET", "ABS", "ASR", "ASSERT", "CHR", "FLOOR", "FLT",
	"INC", "DEC", "LEN", "LSL", "ORD", "PACK", "ROR", "UNPK",
	"WRITE", "READ",  nullptr
};

static bool isOberonKeyword(const char* p, int len) {
    char buf[32];
    if (len <= 0 || len >= 32) return false;
    for (int i = 0; i < len; i++) buf[i] = toupper((unsigned char)p[i]);
    buf[len] = '\0';
    for (int i = 0; OBERON_KEYWORDS[i]; i++)
        if (strcmp(buf, OBERON_KEYWORDS[i]) == 0) return true;
    return false;
}

static const int LNUM_W = 5; // 4 digits + 1 space separator

class TOberonEditor;

class TLineNumbers : public TView {
public:
    TOberonEditor* editor;
    TLineNumbers(TRect bounds) : TView(bounds), editor(nullptr) {
        growMode = gfGrowHiY;
    }
    void draw() override;
};

class TOberonEditor : public TFileEditor {
public:
    TOberonEditor(const TRect& bounds,
                  TScrollBar* hScrollBar,
                  TScrollBar* vScrollBar,
                  TIndicator* indicator,
                  TStringView filename)
        : TFileEditor(bounds, hScrollBar, vScrollBar, indicator, filename),
          errorLine(0), lineNumbers(nullptr)
    {}

    int errorLine;
    std::string errorMsg;
    TLineNumbers* lineNumbers;

    TColorAttr mapColor(uchar index) noexcept override {
        switch (index) {
            case 1: return TColorAttr(TColorRGB(0xC0C0C0), TColorRGB(0x000080));
            case 2: return TColorAttr(TColorRGB(0x000000), TColorRGB(0x00AAAA));
            default: return TFileEditor::mapColor(index);
        }
    }

    void draw() override {
        TFileEditor::draw();

        int firstLine = delta.y;
        int visRows   = size.y;
        int visCols   = size.x;
        int firstCol  = delta.x;

        uint selLo = (selStart <= selEnd) ? selStart : selEnd;
        uint selHi = (selStart <= selEnd) ? selEnd   : selStart;

        auto gapChar = [&](uint i) -> char {
            return buffer[ i < curPtr ? i : i + gapLen ];
        };

        uint lineStart = 0;
        int  lineNo    = 0;
        while (lineNo < firstLine && lineStart < bufLen) {
            if (gapChar(lineStart) == '\n') lineNo++;
            lineStart++;
        }

        // Determine block-comment state at the start of the first visible line
        bool inBlockComment = false;
        for (uint bci = 0; bci + 1 < lineStart; bci++) {
            char c1 = gapChar(bci), c2 = gapChar(bci + 1);
            if (!inBlockComment && c1 == '(' && c2 == '*') { inBlockComment = true;  bci++; }
            else if (inBlockComment && c1 == '*' && c2 == ')') { inBlockComment = false; bci++; }
        }

        for (int row = 0; row < visRows && lineStart <= bufLen; row++) {
            uint lineEnd = lineStart;
            while (lineEnd < bufLen && gapChar(lineEnd) != '\n') lineEnd++;

            auto recolour = [&](uint offset, char ch, TColorAttr ca) {
                if (offset >= selLo && offset < selHi) return;
                int sc = (int)(offset - lineStart) - firstCol;
                if (sc < 0 || sc >= visCols) return;
                TDrawBuffer b;
                b.moveChar(0, ch, ca, 1);
                writeBuf(sc, row, 1, 1, b);
            };

            TColorAttr commentColor = TColorAttr(TColorRGB(0x55FFFF), TColorRGB(0x000080));
            uint i = lineStart;

            // If continuing a block comment from a previous line, consume until *)
            if (inBlockComment) {
                while (i < lineEnd) {
                    if (gapChar(i) == '*' && i + 1 < lineEnd && gapChar(i + 1) == ')') {
                        recolour(i,   gapChar(i),   commentColor);
                        recolour(i+1, gapChar(i+1), commentColor);
                        i += 2;
                        inBlockComment = false;
                        break;
                    }
                    recolour(i, gapChar(i), commentColor);
                    i++;
                }
                if (inBlockComment) {
                    lineStart = lineEnd + 1;
                    continue;
                }
            }

            while (i < lineEnd) {
                char c = gapChar(i);
                if (c == '{') {
                    uint start = i++;
                    while (i < lineEnd && gapChar(i) != '}') i++;
                    if (i < lineEnd) i++;
                    for (uint j = start; j < i; j++) recolour(j, gapChar(j), commentColor);
                    continue;
                }
                if (c == '(' && i+1 < lineEnd && gapChar(i+1) == '*') {
                    uint start = i; i += 2;
                    bool closed = false;
                    while (i < lineEnd) {
                        if (gapChar(i) == '*' && i+1 < lineEnd && gapChar(i+1) == ')') {
                            i += 2; closed = true; break;
                        }
                        i++;
                    }
                    if (!closed) inBlockComment = true;
                    for (uint j = start; j < i; j++) recolour(j, gapChar(j), commentColor);
                    continue;
                }
                if (c == '/' && i+1 < lineEnd && gapChar(i+1) == '/') {
                    for (uint j = i; j < lineEnd; j++) recolour(j, gapChar(j), commentColor);
                    i = lineEnd;
                    continue;
                }
                if (c == '\'') {
                    uint start = i++;
                    while (i < lineEnd) { if (gapChar(i++) == '\'') break; }
                    TColorAttr ca = TColorAttr(TColorRGB(0x55FF55), TColorRGB(0x000080));
                    for (uint j = start; j < i; j++) recolour(j, gapChar(j), ca);
                    continue;
                }
                if (c == '"') {
                    uint start = i++;
                    while (i < lineEnd) { if (gapChar(i++) == '"') break; }
                    TColorAttr ca = TColorAttr(TColorRGB(0x55FF55), TColorRGB(0x000080));
                    for (uint j = start; j < i; j++) recolour(j, gapChar(j), ca);
                    continue;
                }
                if (isdigit((unsigned char)c) ||
                    (c == '$' && i+1 < lineEnd && isxdigit((unsigned char)gapChar(i+1)))) {
                    uint start = i;
                    while (i < lineEnd && (isalnum((unsigned char)gapChar(i)) || gapChar(i) == '.')) i++;
                    for (uint j = start; j < i; j++) recolour(j, gapChar(j), commentColor);
                    continue;
                }
                if (isalpha((unsigned char)c) || c == '_') {
                    uint start = i;
                    while (i < lineEnd && (isalnum((unsigned char)gapChar(i)) || gapChar(i) == '_')) i++;
                    char word[64]; int wlen = std::min((int)(i - start), 63);
                    for (int k = 0; k < wlen; k++) word[k] = gapChar(start + k);
                    word[wlen] = '\0';
                    if (isOberonKeyword(word, wlen)) {
                        TColorAttr ca = TColorAttr(TColorRGB(0xFFFF55), TColorRGB(0x000080));
                        for (uint j = start; j < i; j++) recolour(j, gapChar(j), ca);
                    }
                    continue;
                }
                i++;
            }
            lineStart = lineEnd + 1;
        }

        if (errorLine > 0) {
            int errRow = (errorLine - 1) - delta.y;
            if (errRow >= 0 && errRow < size.y) {
                uint ls = 0; int ln = 0;
                while (ln < errorLine - 1 && ls < bufLen) {
                    if (gapChar(ls) == '\n') ln++;
                    ls++;
                }
                uint le = ls;
                while (le < bufLen && gapChar(le) != '\n') le++;

                TColorAttr errNorm = TColorAttr(TColorRGB(0xFFFFFF), TColorRGB(0xAA0000));
                TColorAttr errKw   = TColorAttr(TColorRGB(0xFFFF55), TColorRGB(0xAA0000));

                TDrawBuffer b;
                b.moveChar(0, ' ', errNorm, size.x);

                uint i2 = ls;
                int contentEnd = 0;
                while (i2 < le) {
                    int logCol = (int)(i2 - ls);
                    if (logCol < delta.x) { i2++; continue; }
                    int sc = logCol - delta.x;
                    if (sc >= size.x) break;

                    char ch = gapChar(i2);
                    TColorAttr ca = errNorm;
                    if (isalpha((unsigned char)ch) || ch == '_') {
                        uint ws = i2;
                        while (i2 < le && (isalnum((unsigned char)gapChar(i2)) || gapChar(i2) == '_')) i2++;
                        char w[64]; int wl = std::min((int)(i2-ws), 63);
                        for (int k = 0; k < wl; k++) w[k] = gapChar(ws+k); w[wl] = 0;
                        ca = isOberonKeyword(w, wl) ? errKw : errNorm;
                        for (uint j = ws; j < i2; j++) {
                            int sc2 = (int)(j - ls) - delta.x;
                            if (sc2 >= 0 && sc2 < size.x) {
                                b.moveChar(sc2, gapChar(j), ca, 1);
                                contentEnd = sc2 + 1;
                            }
                        }
                        continue;
                    }
                    b.moveChar(sc, ch, ca, 1);
                    contentEnd = sc + 1;
                    i2++;
                }

                // Inline error annotation after the code
                if (!errorMsg.empty()) {
                    std::string annot = "  << " + errorMsg;
                    int annotStart = contentEnd + 1;
                    if (annotStart < 2) annotStart = 2;
                    TColorAttr annotColor = TColorAttr(TColorRGB(0xFFFF88), TColorRGB(0x880000));
                    int ac = annotStart;
                    for (char ch : annot) {
                        if (ac >= size.x) break;
                        b.moveChar(ac, ch, annotColor, 1);
                        ac++;
                    }
                }

                writeBuf(0, errRow, size.x, 1, b);
            }
        }

        if (lineNumbers) lineNumbers->drawView();
    }

    void handleEvent(TEvent& event) override {
        if (event.what == evKeyDown) {
            // Any editing key clears the stale error highlight
            ushort kc = event.keyDown.keyCode;
            if (kc != kbF2 && kc != kbF3 && kc != kbF7 &&
                kc != kbF8 && kc != kbF9 && kc != kbCtrlF && kc != kbCtrlH) {
                if (errorLine > 0) {
                    errorLine = 0;
                    errorMsg  = "";
                }
            }
            switch (kc) {
                case kbEnter: {
                    // Auto-indent: only when no selection active
                    if (selStart == selEnd) {
                        // Walk back from cursor to find start of current line
                        uint ls = curPtr;
                        while (ls > 0 && buffer[ls-1] != '\n') ls--;
                        // Collect leading whitespace from that line
                        std::string indent = "\n";
                        for (uint i = ls; i < curPtr; i++) {
                            char c = buffer[i];
                            if (c == ' ' || c == '\t') indent += c;
                            else break;
                        }
                        insertText(indent.c_str(), indent.size(), False);
                        clearEvent(event);
                        return;
                    }
                    break;
                }
                case kbCtrlF: event.what = evCommand; event.message.command = cmFind;        break;
                case kbCtrlH: event.what = evCommand; event.message.command = cmReplace;     break;
                case kbF7:    event.what = evCommand; event.message.command = cmSearchAgain; break;
                case kbF8:    event.what = evCommand; event.message.command = cmCompileOnly; break;
                case kbF9:    event.what = evCommand; event.message.command = cmRunProgram;  break;
                case kbCtrlW: event.what = evCommand; event.message.command = cmCloseWindow; break;
                default: break;
            }
        }
        if (event.what == evCommand) {
            switch (event.message.command) {
                case cmFind:        find();            clearEvent(event); return;
                case cmReplace:     replace();         clearEvent(event); return;
                case cmSearchAgain: doSearchReplace(); clearEvent(event); return;
            }
        }
        TFileEditor::handleEvent(event);
    }
};


void TLineNumbers::draw() {
    TColorAttr normal = TColorAttr(TColorRGB(0x606060), TColorRGB(0x000060));
    TColorAttr errAttr = TColorAttr(TColorRGB(0xFF8080), TColorRGB(0x600000));
    int firstLine = editor ? editor->delta.y : 0;
    int errLine   = editor ? editor->errorLine : 0;
    for (int row = 0; row < size.y; row++) {
        int lineNo = firstLine + row + 1;
        char buf[LNUM_W + 1];
        snprintf(buf, sizeof(buf), "%*d ", LNUM_W - 1, lineNo);
        TColorAttr ca = (lineNo == errLine) ? errAttr : normal;
        TDrawBuffer b;
        b.moveStr(0, buf, ca);
        writeBuf(0, row, size.x, 1, b);
    }
}

// ── Editor Window ─────────────────────────────────────────────────────────
class TEditorWindow : public TWindow {
public:
    TOberonEditor* editor;
    TIndicator*    indicator;
    char         filename[MAXPATH];

    TEditorWindow(TRect bounds, const char* aFile)
        : TWindowInit(&TEditorWindow::initFrame),
          TWindow(bounds,
                  (aFile && *aFile) ? aFile : " Untitled ",
                  wnNoNumber)
    {
        options |= ofTileable;
        TScrollBar* vbar = new TScrollBar(TRect(size.x-1, 1,              size.x,   size.y-1));
        TScrollBar* hbar = new TScrollBar(TRect(1+LNUM_W, size.y-1, size.x-1, size.y));
        insert(vbar);
        insert(hbar);
        indicator = new TIndicator(TRect(0, size.y-1, 12, size.y));
        insert(indicator);
        TLineNumbers* lnum = new TLineNumbers(TRect(1, 1, 1+LNUM_W, size.y-1));
        insert(lnum);
        TRect r(1+LNUM_W, 1, size.x-1, size.y-1);
        if (aFile && *aFile) {
            strncpy(filename, aFile, MAXPATH-1);
            filename[MAXPATH-1] = '\0';
        } else {
            filename[0] = '\0';
        }
        editor = new TOberonEditor(r, hbar, vbar, indicator,
                                   filename[0] ? TStringView(filename) : TStringView());
        insert(editor);
        lnum->editor = editor;
        editor->lineNumbers = lnum;
        editor->select();
    }

    const char* getTitle(short /*maxSize*/) override {
        return filename[0] ? filename : " Untitled ";
    }

    bool writeBufferToFile(const char* path) {
        std::ofstream f(path, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        if (editor->curPtr > 0)
            f.write(editor->buffer, editor->curPtr);
        uint postStart = editor->curPtr + editor->gapLen;
        uint total     = editor->bufLen + editor->gapLen;
        if (postStart < total)
            f.write(editor->buffer + postStart, total - postStart);
        return f.good();
    }

    bool save() {
        if (filename[0] == '\0') return saveAs();
        if (writeBufferToFile(filename)) {
            editor->modified = False;
            return true;
        }
        messageBox(" Error saving file! ", mfError | mfOKButton);
        return false;
    }

    bool saveAs() {
        TFileDialog* dlg = new TFileDialog("*.mod", " Save As ", "~N~ame", fdOKButton, 100);
        bool ok = false;
        if (TProgram::deskTop->execView(dlg) != cmCancel) {
            char buf[MAXPATH] = {};
            dlg->getFileName(buf);
            strncpy(filename, buf, MAXPATH-1);
            if (writeBufferToFile(filename)) {
                editor->modified = False;
                ok = true;
                if (frame) frame->drawView();
            } else {
                messageBox(" Error saving file! ", mfError | mfOKButton);
            }
        }
        TObject::destroy(dlg);
        return ok;
    }

    Boolean valid(ushort command) override {
        if (command == cmQuit || command == cmClose) {
            if (editor->modified) {
                int r = messageBox(
                    " File has unsaved changes. Save before closing?",
                    mfYesNoCancel
                );
                if (r == cmYes)   return Boolean(save());
                if (r == cmNo)    return True;
                return False;
            }
        }
        return TWindow::valid(command);
    }

    std::string getFilePath() {
        if (filename[0] == '\0') {
            if (!saveAs()) return "";
        } else {
            save();
        }
        return std::string(filename);
    }

    void jumpToLine(int targetLine) {
        if (targetLine <= 0) { editor->setCurPtr(0, 0); editor->drawView(); return; }
        uint line = 0;
        uint len  = editor->bufLen;
        for (uint i = 0; i < len; i++) {
            uint phys = (i < editor->curPtr) ? i : i + editor->gapLen;
            if (editor->buffer[phys] == '\n') {
                line++;
                if ((int)line == targetLine) {
                    editor->setCurPtr(i + 1, 0);
                    editor->delta.y = std::max(0, targetLine - editor->size.y / 2);
                    editor->drawView();
                    return;
                }
            }
        }
        editor->setCurPtr(len, 0);
        editor->drawView();
    }

    void handleEvent(TEvent& event) override {
        if (event.what == evCommand) {
            switch (event.message.command) {
                case cmSaveFile:   save();   clearEvent(event); return;
                case cmSaveFileAs: saveAs(); clearEvent(event); return;
            }
        }
        TWindow::handleEvent(event);
    }
};

// ── Application ───────────────────────────────────────────────────────────
class TOberonIDE : public TApplication {
public:
    TOberonIDE();
    void handleEvent(TEvent& event) override;
    static TMenuBar*    initMenuBar(TRect r);
    static TStatusLine* initStatusLine(TRect r);
private:
    void newFile();
    void openFile();
    void saveFile();
    void saveFileAs();
    void runProgram();
    void compileOnly();
    void closeWindow();
    void showAbout();
    void gotoLine();
    void showWindowList();
    void selectWindow(int idx);
    TEditorWindow* activeEditor();

    // Collect all open editor windows in z-order
    std::vector<TEditorWindow*> getEditorWindows();
};

TOberonIDE::TOberonIDE()
    : TProgInit(&TOberonIDE::initStatusLine,
                &TOberonIDE::initMenuBar,
                &TOberonIDE::initDeskTop)
{
    TCommandSet editorCmds;
    editorCmds += cmFind;
    editorCmds += cmReplace;
    editorCmds += cmSearchAgain;
    editorCmds += cmCut;
    editorCmds += cmCopy;
    editorCmds += cmPaste;
    editorCmds += cmUndo;
    editorCmds += cmClear;
    disableCommands(editorCmds);
    TEditor::editorDialog = oberonEditorDialog;
    newFile();
}

TMenuBar* TOberonIDE::initMenuBar(TRect r) {
    r.b.y = r.a.y + 1;
    return new TMenuBar(
        r,
        *new TSubMenu("~F~ile", kbAltF) +
            *new TMenuItem("~N~ew", cmNewFile, kbNoKey, hcNoContext, "") +
            *new TMenuItem("~O~pen...", cmOpenFile, kbF3, hcNoContext, "F3") +
            *new TMenuItem("~S~ave", cmSaveFile, kbF2, hcNoContext, "F2") +
            *new TMenuItem("Save ~A~s...", cmSaveFileAs, kbNoKey) + newLine() +
            *new TMenuItem("E~x~it", cmQuit, kbAltX, hcNoContext, "Alt-X") +
            *new TSubMenu("~E~dit", kbAltE) +
            *new TMenuItem("~U~ndo", cmUndo, kbAltBack, hcNoContext,
                           "Alt-BkSp") +
            newLine() +
            *new TMenuItem("~C~ut", cmCut, kbShiftDel, hcNoContext,
                           "Shift-Del") +
            *new TMenuItem("C~o~py", cmCopy, kbCtrlIns, hcNoContext,
                           "Ctrl-Ins") +
            *new TMenuItem("~P~aste", cmPaste, kbShiftIns, hcNoContext,
                           "Shift-Ins") +
            newLine() + *new TMenuItem("~G~o to Line...", cmGotoLine, kbNoKey) +
            *new TSubMenu("~R~un", kbAltR) +
            *new TMenuItem("~C~ompile", cmCompileOnly, kbF8, hcNoContext, "F8") +
            *new TMenuItem("~R~un",     cmRunProgram,  kbF9, hcNoContext, "F9") +
            *new TSubMenu("~S~earch", kbAltS) +
            *new TMenuItem("~F~ind...", cmFind, kbCtrlF, hcNoContext,
                           "Ctrl-F") +
            *new TMenuItem("~R~eplace...", cmReplace, kbCtrlH, hcNoContext,
                           "Ctrl-H") +
            *new TMenuItem("~A~gain", cmSearchAgain, kbF7, hcNoContext, "F7") +
*new TSubMenu("~W~indow", kbAltW) +
            *new TMenuItem("~C~lose",        cmCloseWindow, kbCtrlW, hcNoContext, "Ctrl-W") +
            *new TMenuItem("~L~ist...",      cmWindowList,  kbNoKey, hcNoContext, "") +
            *new TMenuItem("Switch Window",  cmWindow1 + 1, kbAlt2,  hcNoContext, "Alt-2") +
            
        *new TSubMenu("~H~elp", kbAltH) +
            *new TMenuItem("~A~bout...",      cmAbout,      kbNoKey)
    );
}

TStatusLine* TOberonIDE::initStatusLine(TRect r) {
    r.a.y = r.b.y - 1;
    return new TStatusLine(r,
        *new TStatusDef(0, 0xFFFF) +
            *new TStatusItem("~F2~ Save",    kbF2,   cmSaveFile)   +
            *new TStatusItem("~F3~ Open",    kbF3,   cmOpenFile)   +
            *new TStatusItem("~F7~ Again",   kbF7,   cmSearchAgain) +
            *new TStatusItem("~F8~ Compile", kbF8,   cmCompileOnly) +
            *new TStatusItem("~F9~ Run",     kbF9,   cmRunProgram) +
            *new TStatusItem("~Alt-X~ Exit", kbAltX, cmQuit)
    );
}

TEditorWindow* TOberonIDE::activeEditor() {
    return dynamic_cast<TEditorWindow*>(deskTop->current);
}

std::vector<TEditorWindow*> TOberonIDE::getEditorWindows() {
    std::vector<TEditorWindow*> windows;
    if (!deskTop || !deskTop->last) return windows;
    TView* start = deskTop->last->next;
    TView* v = start;
    int count = 0;
    do {
        if (auto* w = dynamic_cast<TEditorWindow*>(v))
            windows.push_back(w);
        v = v->next;
        if (++count > 100) break;
    } while (v != start);
    return windows;
}

void TOberonIDE::handleEvent(TEvent& event) {
  if (event.what == evCommand) {
if (event.message.command >= cmWindow1 && event.message.command < cmWindow1 + 40) {
            selectWindow(event.message.command - cmWindow1);
            clearEvent(event);
            return;
        }    
        switch (event.message.command) {
            case cmNewFile:    newFile();        clearEvent(event); return;
            case cmOpenFile:   openFile();       clearEvent(event); return;
            case cmSaveFile:   saveFile();       clearEvent(event); return;
            case cmSaveFileAs: saveFileAs();     clearEvent(event); return;
            case cmRunProgram:  runProgram();     clearEvent(event); return;
            case cmCompileOnly: compileOnly();   clearEvent(event); return;
            case cmCloseWindow: closeWindow();   clearEvent(event); return;
            case cmAbout:      showAbout();      clearEvent(event); return;
            case cmGotoLine:   gotoLine();       clearEvent(event); return;
            case cmWindowList: showWindowList(); clearEvent(event); return;
            default:
                break;
        }
    }
    TApplication::handleEvent(event);
}

void TOberonIDE::showWindowList() {
    auto windows = getEditorWindows();
    if (windows.empty()) {
        messageBox(" No editor windows open. ", mfInformation | mfOKButton);
        return;
    }

    int count = (int)windows.size();
    int listCount = std::min(count, 14);

    // Build display: each line "N. filename"
    // Dialog height: 2 header + listCount lines + 1 gap + 1 input + 1 gap + 1 buttons + 1 border = listCount+6
    int dlgH = listCount + 7;
    int dlgW = 64;

    auto* dlg = new TDialog(TRect(0, 0, dlgW, dlgH), " Window List ");
    dlg->options |= ofCentered;

    // Show file list as static text lines
    for (int i = 0; i < listCount; i++) {
        const char* fullname = windows[i]->filename[0]
                               ? windows[i]->filename : "Untitled";
        const char* slash = strrchr(fullname, '/');
        const char* name = slash ? slash + 1 : fullname;
        char label[62];
        bool modified = windows[i]->editor->modified;
        snprintf(label, sizeof(label), "%d. %s%s", i+1, name, modified ? " *" : "");
        dlg->insert(new TStaticText(TRect(2, 1+i, dlgW-2, 2+i), label));
    }

    // Number input
    int inputY = listCount + 2;
    auto* inp = new TInputLine(TRect(18, inputY, 22, inputY+1), 4);
    dlg->insert(new TLabel(TRect(2, inputY, 18, inputY+1), "~G~o to window #:", inp));
    dlg->insert(inp);

    int btnY = inputY + 2;
    dlg->insert(new TButton(TRect(dlgW/2-12, btnY, dlgW/2-2, btnY+1),
                            " ~O~K ", cmOK, bfDefault));
    dlg->insert(new TButton(TRect(dlgW/2+2,  btnY, dlgW/2+12, btnY+1),
                            " ~C~ancel ", cmCancel, bfNormal));
    dlg->selectNext(False);
    inp->select();

    ushort result = deskTop->execView(dlg);
    char buf[8] = {};
    inp->getData(buf);
    TObject::destroy(dlg);

    if (result == cmOK) {
        int n = atoi(buf);
        if (n >= 1 && n <= listCount)
            selectWindow(n - 1);
    }
}

void TOberonIDE::selectWindow(int idx) {
    auto windows = getEditorWindows();
    if (idx < 0 || idx >= (int)windows.size()) return;
    TEditorWindow* w = windows[idx];
    // Bring to front and focus
    w->select();
    w->makeFirst();
}

void TOberonIDE::newFile() {
    TRect r = deskTop->getExtent();
    r.grow(-2, -1);
    deskTop->insert(new TEditorWindow(r, nullptr));
}

void TOberonIDE::openFile() {
    TFileDialog* dlg = new TFileDialog("*.mod", " Open Oberon File ",
                                       "~N~ame", fdOpenButton, 100);
    if (deskTop->execView(dlg) != cmCancel) {
        char buf[MAXPATH] = {};
        dlg->getFileName(buf);
        TRect r = deskTop->getExtent();
        r.grow(-2, -1);
        deskTop->insert(new TEditorWindow(r, buf));
    }
    TObject::destroy(dlg);
}

void TOberonIDE::saveFile()   { if (auto* w = activeEditor()) w->save(); }
void TOberonIDE::saveFileAs() { if (auto* w = activeEditor()) w->saveAs(); }

void TOberonIDE::runProgram() {
    auto* w = activeEditor();
    if (!w) { messageBox(" No editor open. ", mfError | mfOKButton); return; }
    std::string path = w->getFilePath();
    if (path.empty()) return;
    w->editor->errorLine = 0;
    w->editor->errorMsg = "";
    RunResult result = runOberon(path.c_str());
    if (result.errorLine > 0) {
        w->editor->errorLine = result.errorLine;

        // Extract short error message for inline annotation
        const std::string& s = result.errorText;
        std::string msg;
        size_t ep = s.find(": error: ");
        if (ep != std::string::npos) {
            size_t ms = ep + 9;
            size_t nl = s.find('\n', ms);
            msg = s.substr(ms, nl == std::string::npos ? std::string::npos : nl - ms);
        } else {
            size_t i = 0;
            while (i < s.size() && (s[i] == '\n' || s[i] == '\r')) i++;
            size_t nl = s.find('\n', i);
            msg = s.substr(i, nl == std::string::npos ? std::string::npos : nl - i);
        }
        w->editor->errorMsg = msg;
    }
    if (!result.errorText.empty()) {
        TOutputDialog* dlg = new TOutputDialog(result.errorText, false);
        deskTop->execView(dlg);
        TObject::destroy(dlg);
    }
    if (result.errorLine > 0) {
        w->jumpToLine(result.errorLine - 1);
        w->drawView();
    }
}

void TOberonIDE::compileOnly() {
    auto* w = activeEditor();
    if (!w) { messageBox(" No editor open. ", mfError | mfOKButton); return; }
    std::string path = w->getFilePath();
    if (path.empty()) return;
    w->editor->errorLine = 0;
    w->editor->errorMsg = "";
    RunResult result = runOberon(path.c_str(), false);
    if (result.errorLine > 0) {
        w->editor->errorLine = result.errorLine;
        const std::string& s = result.errorText;
        std::string msg;
        size_t ep = s.find(": error: ");
        if (ep != std::string::npos) {
            size_t ms = ep + 9;
            size_t nl = s.find('\n', ms);
            msg = s.substr(ms, nl == std::string::npos ? std::string::npos : nl - ms);
        } else {
            size_t i = 0;
            while (i < s.size() && (s[i] == '\n' || s[i] == '\r')) i++;
            size_t nl = s.find('\n', i);
            msg = s.substr(i, nl == std::string::npos ? std::string::npos : nl - i);
        }
        w->editor->errorMsg = msg;
    }
    if (!result.errorText.empty()) {
        TOutputDialog* dlg = new TOutputDialog(result.errorText, result.errorLine == 0);
        deskTop->execView(dlg);
        TObject::destroy(dlg);
    }
    if (result.errorLine > 0) {
        w->jumpToLine(result.errorLine - 1);
        w->drawView();
    }
}

void TOberonIDE::closeWindow() {
    if (auto* w = activeEditor())
        w->close();
}

void TOberonIDE::showAbout() {
    auto* dlg = new TDialog(TRect(0,0,50,12), " About Oberon IDE ");
    dlg->options |= ofCentered;
    dlg->insert(new TStaticText(TRect(2,2,48,3), " Oberon IDE  v1.0"));
    dlg->insert(new TStaticText(TRect(2,3,48,4), " Built on tvision (magiblot)"));
    dlg->insert(new TStaticText(TRect(2,5,48,6), " F2  Save         F3  Open"));
    dlg->insert(new TStaticText(TRect(2,6,48,7), " F9  Run"));
    dlg->insert(new TStaticText(TRect(2,7,48,8), " Alt-W  Window list"));
    dlg->insert(new TStaticText(TRect(2,8,48,9), " Alt-X  Exit"));
    dlg->insert(new TButton(TRect(20,10,30,11), "  ~O~K  ", cmOK, bfDefault));
    deskTop->execView(dlg);
    TObject::destroy(dlg);
}

void TOberonIDE::gotoLine() {
    auto* w = activeEditor();
    if (!w) return;
    auto* dlg = new TDialog(TRect(0,0,36,8), " Go to Line ");
    dlg->options |= ofCentered;
    auto* inp = new TInputLine(TRect(2,3,34,4), 10);
    dlg->insert(new TLabel(TRect(2,2,20,3), "~L~ine number:", inp));
    dlg->insert(inp);
    dlg->insert(new TButton(TRect(4,5,14,6),  " ~O~K ",     cmOK,     bfDefault));
    dlg->insert(new TButton(TRect(16,5,28,6), " ~C~ancel ", cmCancel, bfNormal));
    dlg->selectNext(False);
    if (deskTop->execView(dlg) != cmCancel) {
        char buf[16] = {};
        inp->getData(buf);
        int line = atoi(buf);
        if (line > 0) w->jumpToLine(line - 1);
    }
    TObject::destroy(dlg);
}

int main(int argc, char* argv[]) {
    TOberonIDE app;
    if (argc >= 2) {
        TRect r = app.deskTop->getExtent();
        r.grow(-2, -1);
        app.deskTop->insert(new TEditorWindow(r, argv[1]));
    }
    app.run();
    return 0;
}
