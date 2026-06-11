namespace AINotebook.App.Services;

public interface ISecretStore
{
    void Save(string id, string secret);
    string? Load(string id);
    void Delete(string id);
}
