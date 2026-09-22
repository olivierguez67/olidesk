// UninstallCleanup.cpp — the "keep or wipe settings" choice at uninstall
// time, and the actual wipe.
//
//  - PromptKeepSettings: immediate CA, runs early in InstallExecuteSequence
//    (After="InstallInitialize", Condition="REMOVE=\"ALL\" AND NOT
//    UPGRADINGPRODUCTCODE" -- a real uninstall, not an upgrade's
//    remove-then-reinstall step). Sets the KEEPSETTINGS property.
//
//    Deliberately does NOT use a WiX Dialog-table dialog for this: those
//    live in InstallUISequence, and Windows' Settings > Apps uninstall
//    flow is well known not to run that sequence at full UI even though
//    its own UninstallString has no /q override -- WixUI dialogs silently
//    don't show there in practice. A native TaskDialogIndirect call here
//    instead is just a normal Win32 API call from inside a custom action;
//    it doesn't depend on MSI's own dialog engine or UI-sequence at all,
//    so it shows regardless of whichever mechanism suppresses WixUI
//    dialogs specifically for that path.
//
//    Three ways KEEPSETTINGS ends up set, in priority order:
//    1. Already explicitly passed on the command line (silent uninstall,
//       e.g. `msiexec /x ... KEEPSETTINGS=0 /qn`) -- respected as-is, no
//       prompt.
//    2. A genuinely silent run with nothing passed (UILevel indicates no
//       UI at all, i.e. /qn with no KEEPSETTINGS override) -- defaults to
//       "1" (keep), no prompt, since popping a native dialog during a
//       supposedly unattended run would be its own bug.
//    3. Otherwise: shows the TaskDialog. OK uses the checkbox state
//       (checked by default); Cancel (or closing the dialog) aborts the
//       uninstall entirely, same as declining a normal confirmation.
//
//  - RemoveOlideskSettings: deferred CA, runs later in
//    InstallExecuteSequence, Condition="REMOVE=\"ALL\" AND NOT
//    UPGRADINGPRODUCTCODE AND KEEPSETTINGS<>\"1\"" -- only when the user
//    (or a silent install) explicitly chose not to keep settings. Not
//    impersonated: deleting other users' AppData and machine-wide registry
//    keys needs the elevated context deferred custom actions already run
//    in for a per-machine install, not the interactive user's own token.
//
// Both compiled into every build (admin and client): the choice applies
// equally to either, unlike the deployment-specific custom actions in
// DeployConfig.cpp which are client-build-only.

#include "pch.h"
#include <commctrl.h>
#include <shellapi.h>
#include <string>
#include <vector>
#include <cstdarg>

#include "./Common.h"

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "shell32.lib")

namespace {

// Same MsiProcessMessage-direct approach as DeployConfig.cpp's LogInfo --
// duplicated locally rather than shared across translation units, since
// each custom-action .cpp file in this project is self-contained. Used
// only by RemoveOlideskSettings; PromptKeepSettings uses WcaLog (a
// deferred CA, confirmed via a real verbose log elsewhere in this project
// to reach the log reliably, unlike an immediate/impersonated one).
void LogInfo(MSIHANDLE hInstall, const wchar_t* fmt, ...)
{
    wchar_t buf[2048];
    va_list args;
    va_start(args, fmt);
    vswprintf_s(buf, fmt, args);
    va_end(args);

    PMSIHANDLE hRec = MsiCreateRecord(1);
    MsiRecordSetStringW(hRec, 0, L"[1]");
    MsiRecordSetStringW(hRec, 1, buf);
    MsiProcessMessage(hInstall, INSTALLMESSAGE_INFO, hRec);
}

// ---------------------------------------------------------------------
// Safety
//
// RemoveOlideskSettings runs deferred, unimpersonated (elevated) and
// recursively deletes directory trees computed from enumerated user
// profile paths. A bug in that path computation turning into mass data
// loss elsewhere on the machine is the single biggest risk in this file,
// so every path gets checked here immediately before deletion, no matter
// how it was built: refuse anything that doesn't end in exactly
// "\RustDesk" (templated to "\Olidesk" at build time -- see
// preprocess.py's replace_app_name_in_custom_actions), regardless of what
// came before it in the path.
// ---------------------------------------------------------------------

bool LooksLikeOurFolder(const std::wstring& path)
{
    if (path.size() < 10) return false;
    size_t pos = path.find_last_of(L"\\/");
    if (pos == std::wstring::npos || pos + 1 >= path.size()) return false;
    std::wstring last = path.substr(pos + 1);
    return _wcsicmp(last.c_str(), L"RustDesk") == 0;
}

// Recursively deletes a folder via SHFileOperationW (silent, no UI, no
// recycle-bin prompt), after the LooksLikeOurFolder safety check. A
// non-existent path is treated as success (nothing to do), not a failure.
bool RecursiveDeleteFolder(MSIHANDLE hInstall, const std::wstring& path)
{
    if (!LooksLikeOurFolder(path))
    {
        LogInfo(hInstall, L"RemoveOlideskSettings: refusing to delete suspicious path '%s'.", path.c_str());
        return false;
    }

    DWORD attrs = GetFileAttributesW(path.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES)
    {
        return true; // Doesn't exist -- nothing to do, not an error.
    }

    // SHFileOperationW's pFrom wants a double-null-terminated string.
    std::wstring doubleNull = path;
    doubleNull.push_back(L'\0');
    doubleNull.push_back(L'\0');

    SHFILEOPSTRUCTW op = {};
    op.wFunc = FO_DELETE;
    op.pFrom = doubleNull.c_str();
    op.fFlags = FOF_NO_UI | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR;

    int result = SHFileOperationW(&op);
    if (result != 0 || op.fAnyOperationsAborted)
    {
        LogInfo(hInstall, L"RemoveOlideskSettings: failed to delete '%s' (result=%d).", path.c_str(), result);
        return false;
    }

    LogInfo(hInstall, L"RemoveOlideskSettings: deleted '%s'.", path.c_str());
    return true;
}

// Every interactive user's roaming AppData copy of the app's own config/
// log directory (device ID, keypair, local options including the
// registration flag -- see Config::path()/LocalConfig in
// libs/hbb_common/src/config.rs). Enumerated from ProfileList rather than
// just the current user, since an admin uninstalling on behalf of someone
// else, or a machine with multiple accounts that have each run the app,
// both need every copy wiped for a genuinely clean slate.
std::vector<std::wstring> EnumerateUserProfileAppDataFolders(MSIHANDLE hInstall)
{
    std::vector<std::wstring> results;

    HKEY hProfileList;
    LONG r = RegOpenKeyExW(HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList",
        0, KEY_READ, &hProfileList);
    if (r != ERROR_SUCCESS)
    {
        LogInfo(hInstall, L"RemoveOlideskSettings: could not open ProfileList (error %ld).", r);
        return results;
    }

    wchar_t subKeyName[256];
    DWORD index = 0;
    while (true)
    {
        DWORD cchName = ARRAYSIZE(subKeyName);
        LONG er = RegEnumKeyExW(hProfileList, index, subKeyName, &cchName, NULL, NULL, NULL, NULL);
        if (er == ERROR_NO_MORE_ITEMS)
        {
            break;
        }
        index++;
        if (er != ERROR_SUCCESS)
        {
            continue;
        }

        HKEY hProfile;
        if (RegOpenKeyExW(hProfileList, subKeyName, 0, KEY_READ, &hProfile) != ERROR_SUCCESS)
        {
            continue;
        }

        wchar_t rawPath[MAX_PATH] = { 0 };
        DWORD cbPath = sizeof(rawPath);
        DWORD type = 0;
        if (RegQueryValueExW(hProfile, L"ProfileImagePath", NULL, &type, (LPBYTE)rawPath, &cbPath) == ERROR_SUCCESS
            && rawPath[0] != L'\0')
        {
            wchar_t expanded[MAX_PATH] = { 0 };
            if (type == REG_EXPAND_SZ)
            {
                ExpandEnvironmentStringsW(rawPath, expanded, ARRAYSIZE(expanded));
            }
            else
            {
                wcsncpy_s(expanded, rawPath, _TRUNCATE);
            }
            if (expanded[0] != L'\0')
            {
                results.push_back(std::wstring(expanded) + L"\\AppData\\Roaming\\RustDesk");
            }
        }
        RegCloseKey(hProfile);
    }
    RegCloseKey(hProfileList);

    LogInfo(hInstall, L"RemoveOlideskSettings: found %zu user profile(s) to check.", results.size());
    return results;
}

// The app's runtime-written ProgID registry entries (file/URL-protocol
// association; see get_after_install()/get_before_uninstall() in
// src/platform/windows.rs). Lowercase, matching the app's own literal
// naming there -- not templated by preprocess.py's RustDesk->app_name
// substitution, which only matches the capitalized word "RustDesk".
// Scoped to HKLM (the machine-wide Classes hive, always reachable from
// this elevated, unimpersonated deferred CA); a per-user HKCU copy, if
// the app ever wrote one while running unelevated as some other user, is
// out of reach here and not covered.
void DeleteClassesRootKey(MSIHANDLE hInstall, LPCWSTR name)
{
    std::wstring keyPath = std::wstring(L"SOFTWARE\\Classes\\") + name;
    LONG r = RegDeleteTreeW(HKEY_LOCAL_MACHINE, keyPath.c_str());
    if (r == ERROR_SUCCESS)
    {
        LogInfo(hInstall, L"RemoveOlideskSettings: deleted registry key HKLM\\%s.", keyPath.c_str());
    }
    else if (r != ERROR_FILE_NOT_FOUND)
    {
        LogInfo(hInstall, L"RemoveOlideskSettings: failed to delete HKLM\\%s (error %ld).", keyPath.c_str(), r);
    }
}

} // namespace

UINT __stdcall RemoveOlideskSettings(__in MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    DWORD er = ERROR_SUCCESS;

    hr = WcaInitialize(hInstall, "RemoveOlideskSettings");
    ExitOnFailure(hr, "Failed to initialize");

    LogInfo(hInstall, L"RemoveOlideskSettings: starting.");

    for (const auto& folder : EnumerateUserProfileAppDataFolders(hInstall))
    {
        RecursiveDeleteFolder(hInstall, folder);
    }

    // The Windows service runs as LocalSystem (see MyCreateServiceW in
    // ServiceUtils.cpp), but Config::patch() in
    // libs/hbb_common/src/config.rs redirects its own config/log reads
    // and writes to the LocalService profile instead of the true SYSTEM
    // profile -- so that's the copy that actually exists on disk and
    // needs wiping, distinct from any interactive user's.
    RecursiveDeleteFolder(hInstall,
        L"C:\\Windows\\ServiceProfiles\\LocalService\\AppData\\Roaming\\RustDesk");

    // ProgramData\RustDesk: recordings (see ui_interface.rs) and anything
    // else the app writes there at runtime. MSI has no Component tracking
    // this folder's contents (only the empty directory itself is
    // declared, unreferenced, in Folders.wxs), so this is the only thing
    // that ever cleans it up.
    {
        wchar_t programData[MAX_PATH] = { 0 };
        DWORD cch = GetEnvironmentVariableW(L"ProgramData", programData, ARRAYSIZE(programData));
        if (cch > 0 && cch < ARRAYSIZE(programData))
        {
            RecursiveDeleteFolder(hInstall, std::wstring(programData) + L"\\RustDesk");
        }
    }

    DeleteClassesRootKey(hInstall, L".olidesk");
    DeleteClassesRootKey(hInstall, L"olidesk");

    LogInfo(hInstall, L"RemoveOlideskSettings: finished.");

LExit:
    er = ERROR_SUCCESS; // Never fail the uninstall itself over a cleanup problem.
    return WcaFinalize(er);
}

UINT __stdcall PromptKeepSettings(__in MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    DWORD er = ERROR_SUCCESS;

    hr = WcaInitialize(hInstall, "PromptKeepSettings");
    ExitOnFailure(hr, "Failed to initialize");

    {
        wchar_t existing[8] = { 0 };
        DWORD cchExisting = ARRAYSIZE(existing);
        MsiGetPropertyW(hInstall, L"KEEPSETTINGS", existing, &cchExisting);
        if (existing[0] != L'\0')
        {
            WcaLog(LOGMSG_STANDARD, "PromptKeepSettings: KEEPSETTINGS already set to '%ls', not prompting.", existing);
            goto LExit;
        }

        wchar_t uiLevelStr[16] = { 0 };
        DWORD cchUiLevel = ARRAYSIZE(uiLevelStr);
        MsiGetPropertyW(hInstall, L"UILevel", uiLevelStr, &cchUiLevel);
        // INSTALLUILEVEL_NONE = 2 (msiexec /qn). Default 5 (full) if the
        // property is somehow unreadable, which just means "prompt as
        // normal" -- the safer failure mode.
        int uiLevel = uiLevelStr[0] ? _wtoi(uiLevelStr) : 5;
        if (uiLevel <= 2)
        {
            WcaLog(LOGMSG_STANDARD, "PromptKeepSettings: silent uninstall (UILevel=%d), defaulting KEEPSETTINGS=1.", uiLevel);
            MsiSetPropertyW(hInstall, L"KEEPSETTINGS", L"1");
            goto LExit;
        }

        TASKDIALOGCONFIG config = {};
        config.cbSize = sizeof(config);
        config.dwFlags = TDF_VERIFICATION_FLAG_CHECKED | TDF_ALLOW_DIALOG_CANCELLATION;
        config.pszWindowTitle = L"RustDesk Uninstall";
        config.pszMainInstruction = L"Uninstall RustDesk?";
        config.pszContent = L"This removes RustDesk from this computer.";
        config.pszVerificationText =
            L"Keep settings (device ID and registration) for a future reinstall";
        config.dwCommonButtons = TDCBF_OK_BUTTON | TDCBF_CANCEL_BUTTON;

        BOOL checked = TRUE;
        int button = 0;
        HRESULT hrDlg = TaskDialogIndirect(&config, &button, NULL, &checked);

        if (FAILED(hrDlg))
        {
            // Couldn't show the dialog at all (e.g. no interactive session
            // despite UILevel suggesting one) -- default to the safe
            // choice, same as the silent-uninstall path above, rather than
            // block the uninstall over a UI failure.
            WcaLog(LOGMSG_STANDARD, "PromptKeepSettings: TaskDialogIndirect failed (0x%08lx), defaulting KEEPSETTINGS=1.", hrDlg);
            MsiSetPropertyW(hInstall, L"KEEPSETTINGS", L"1");
            goto LExit;
        }

        if (button == IDCANCEL)
        {
            WcaLog(LOGMSG_STANDARD, "PromptKeepSettings: user cancelled, aborting uninstall.");
            er = ERROR_INSTALL_USEREXIT;
            goto LExit;
        }

        WcaLog(LOGMSG_STANDARD, "PromptKeepSettings: KEEPSETTINGS=%d (checkbox).", checked ? 1 : 0);
        MsiSetPropertyW(hInstall, L"KEEPSETTINGS", checked ? L"1" : L"0");
    }

LExit:
    return WcaFinalize(er);
}
