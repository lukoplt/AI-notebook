using Windows.Security.Credentials;

namespace AINotebook.App.Services;

/// <summary>
/// API keys stored exclusively in Windows Credential Manager (PasswordVault).
/// Keys never written to SQLite — only a provider UUID reference lives in the DB.
/// </summary>
public sealed class WindowsPasswordVaultSecretStore : ISecretStore
{
    private const string Resource = "AINotebook";

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
        catch (Exception ex) when (ex.HResult == unchecked((int)0x80070490))
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
        catch { /* not stored — nothing to remove */ }
    }
}
