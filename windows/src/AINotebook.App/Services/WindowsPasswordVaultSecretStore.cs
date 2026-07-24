using Windows.Security.Credentials;

namespace AINotebook.App.Services;

/// <summary>
/// API keys stored exclusively in Windows Credential Manager (PasswordVault).
/// Keys never written to SQLite — only a provider UUID reference lives in the DB.
/// </summary>
public sealed class WindowsPasswordVaultSecretStore : ISecretStore
{
    private const string Resource = "AINotebook";

    /// HRESULT for ERROR_NOT_FOUND, which PasswordVault raises for a lookup
    /// that matched nothing. The only failure either operation may ignore.
    private const int ElementNotFound = unchecked((int)0x80070490);

    public void Save(string id, string secret)
    {
        Delete(id); // PasswordVault throws on duplicate — remove first
        var vault = new PasswordVault();
        vault.Add(new PasswordCredential(Resource, id, secret));
    }

    public string? Load(string id)
    {
        try
        {
            var vault = new PasswordVault();
            var cred = vault.Retrieve(Resource, id);
            cred.RetrievePassword();
            return cred.Password;
        }
        catch (Exception ex) when (ex.HResult == ElementNotFound)
        {
            // Element not found — key was never stored.
            return null;
        }
    }

    public void Delete(string id)
    {
        try
        {
            var vault = new PasswordVault();
            var cred = vault.Retrieve(Resource, id);
            vault.Remove(cred);
        }
        catch (Exception ex) when (ex.HResult == ElementNotFound)
        {
            // Not stored — nothing to remove.
        }
        // Any other failure propagates. Swallowing everything here meant a
        // credential that genuinely could not be removed looked deleted, and
        // then Save()'s delete-first step silently left the old entry in place
        // so the following Add() threw on the duplicate instead.
    }
}
