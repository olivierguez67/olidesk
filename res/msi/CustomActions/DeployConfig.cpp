// DeployConfig.cpp — WriteDeployJson, the one custom action behind silent-
// install deployment (Package/Components/RustDesk.wxs):
//
//  - WriteDeployJson: deferred CA, runs after InstallFiles. Writes
//    olidesk-deploy.json into the install folder from DEVICENAME, GROUP,
//    API_URL and ENROLLCODE (all plain MSI properties, settable via
//    msiexec /i ... ENROLLCODE="XXXX-XXXX" GROUP="..." DEVICENAME="..." /qn),
//    so the app can self-register on first launch
//    (flutter/lib/common/olidesk_deploy.dart) without needing that file
//    dropped in by hand after install, and without showing any dialog of
//    its own. If ENROLLCODE wasn't passed (a plain interactive install with
//    no deployment properties), no file is written at all -- the app's own
//    "Register this device" dialog (flutter/lib/common/widgets/
//    olidesk_register_device.dart) handles registration entirely on first
//    launch in that case.
//
//    An earlier version of this installer also had an immediate,
//    network-calling FetchGroups custom action and an interactive
//    DeployConfigDlg dialog (device name / group combo box), with a
//    long-lived deploy token baked into the MSI so FetchGroups could call
//    the server. That whole approach was replaced: no secret of any kind
//    ships in a public installer anymore (ENROLLCODE is a short-lived,
//    revocable, per-batch code, not a long-lived credential), and the
//    group-picking UI moved into the app itself, where it can actually
//    reach the network reliably and be tested without waiting on a full
//    MSI rebuild. See ENROLL_CODE_TTL and /api/admin/enrollment-codes in
//    olidesk-api/app.py, and olidesk_register_device.dart.
//
// Compiled in only when the installer was built with --api-url (see
// ../preprocess.py and the `<?ifdef ApiUrl?>` guards throughout the
// Package/*.wxs files) -- i.e. the client build, not the admin build.

#include "pch.h"
#include <strutil.h>
#include <string>
#include <vector>
#include <sstream>
#include <cstdarg>

#include "./Common.h"

namespace {

// ---------------------------------------------------------------------
// Logging
//
// Talks to MsiProcessMessage(INSTALLMESSAGE_INFO) directly rather than
// through WcaLog -- confirmed, via a real verbose install log, to reach the
// log reliably for this action (WriteDeployJson is a deferred, server-side
// custom action; "MSI (s)" in a verbose log). The same wasn't true for the
// old immediate, impersonated FetchGroups action, which no longer exists.
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
// UTF-8 / UTF-16 conversion
// ---------------------------------------------------------------------

std::string WideToUtf8(const std::wstring& wide)
{
    if (wide.empty()) return std::string();
    int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), NULL, 0, NULL, NULL);
    if (size <= 0) return std::string();
    std::string result(size, 0);
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), &result[0], size, NULL, NULL);
    return result;
}

// ---------------------------------------------------------------------
// Minimal JSON string escaping -- just enough for the fields we write
// (api_url, enroll_code, group, device_name), not a general-purpose
// serializer.
// ---------------------------------------------------------------------

std::wstring JsonEscape(const std::wstring& in)
{
    std::wstring out;
    out.reserve(in.size());
    for (wchar_t c : in)
    {
        switch (c)
        {
        case L'"': out += L"\\\""; break;
        case L'\\': out += L"\\\\"; break;
        case L'\n': out += L"\\n"; break;
        case L'\r': out += L"\\r"; break;
        case L'\t': out += L"\\t"; break;
        default:
            if (c < 0x20)
            {
                wchar_t buf[8];
                swprintf_s(buf, L"\\u%04x", c);
                out += buf;
            }
            else
            {
                out += c;
            }
        }
    }
    return out;
}

} // namespace

UINT __stdcall WriteDeployJson(__in MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    DWORD er = ERROR_SUCCESS;

    LPWSTR pwzData = NULL;

    hr = WcaInitialize(hInstall, "WriteDeployJson");
    ExitOnFailure(hr, "Failed to initialize");

    LogInfo(hInstall, L"WriteDeployJson: starting.");

    hr = WcaGetProperty(L"CustomActionData", &pwzData);
    ExitOnFailure(hr, "failed to get CustomActionData");

    {
        std::wstring installFolder, deviceName, group, apiUrl, enrollCode;

        // Fields are joined with this marker string by
        // WriteDeployJson.SetParam in RustDesk.wxs, not a printable
        // character like ';', since DEVICENAME/GROUP are free text passed
        // on the command line and could otherwise collide with the
        // delimiter. Plain ASCII: a first attempt used U+E000 (Private Use
        // Area, chosen to be XML-legal and untypeable), but that broke the
        // WiX build -- U+E000 isn't representable in the MSI database's
        // default Windows-1252 codepage.
        static const std::wstring kSep = L"##OLIDESK_SEP##";
        std::wstring all(pwzData ? pwzData : L"");
        std::vector<std::wstring> fields;
        size_t start = 0;
        while (true)
        {
            size_t pos = all.find(kSep, start);
            if (pos == std::wstring::npos)
            {
                fields.push_back(all.substr(start));
                break;
            }
            fields.push_back(all.substr(start, pos - start));
            start = pos + kSep.size();
        }

        if (fields.size() != 5)
        {
            LogInfo(hInstall, L"WriteDeployJson: expected 5 fields, got %zu; aborting.", fields.size());
            goto LExit;
        }

        installFolder = fields[0];
        deviceName = fields[1];
        group = fields[2];
        apiUrl = fields[3];
        enrollCode = fields[4];

        // Never log enrollCode itself -- everything below logs
        // installFolder/deviceName/group/apiUrl freely, but that variable
        // never appears in a LogInfo call anywhere in this function.
        if (installFolder.empty())
        {
            LogInfo(hInstall, L"WriteDeployJson: install folder is empty, aborting.");
            goto LExit;
        }
        if (apiUrl.empty() || enrollCode.empty())
        {
            // Not an error: a plain interactive install with no deployment
            // properties passed has no ENROLLCODE, and that's the expected,
            // common case now that the app's own dialog handles
            // registration. Just skip writing a file with nothing useful
            // in it.
            LogInfo(hInstall, L"WriteDeployJson: API_URL or ENROLLCODE not set, skipping.");
            goto LExit;
        }

        std::wstringstream json;
        json << L"{\n"
             << L"  \"api_url\": \"" << JsonEscape(apiUrl) << L"\",\n"
             << L"  \"enroll_code\": \"" << JsonEscape(enrollCode) << L"\",\n"
             << L"  \"group\": \"" << JsonEscape(group) << L"\",\n"
             << L"  \"device_name\": \"" << JsonEscape(deviceName) << L"\"\n"
             << L"}\n";

        std::wstring path = installFolder;
        if (!path.empty() && path.back() != L'\\' && path.back() != L'/')
        {
            path += L'\\';
        }
        path += L"olidesk-deploy.json";

        std::string utf8 = WideToUtf8(json.str());

        HANDLE hFile = CreateFileW(path.c_str(), GENERIC_WRITE, 0, NULL,
            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hFile == INVALID_HANDLE_VALUE)
        {
            LogInfo(hInstall, L"WriteDeployJson: failed to create '%s', error %lu",
                path.c_str(), GetLastError());
            goto LExit;
        }

        DWORD written = 0;
        BOOL wrote = WriteFile(hFile, utf8.data(), (DWORD)utf8.size(), &written, NULL);
        CloseHandle(hFile);

        if (!wrote || written != utf8.size())
        {
            LogInfo(hInstall, L"WriteDeployJson: failed to write '%s', error %lu",
                path.c_str(), GetLastError());
            goto LExit;
        }

        LogInfo(hInstall, L"WriteDeployJson: wrote '%s' (group='%s', device_name='%s').",
            path.c_str(), group.c_str(), deviceName.c_str());
    }

LExit:
    if (pwzData)
    {
        ReleaseStr(pwzData);
    }

    er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}
