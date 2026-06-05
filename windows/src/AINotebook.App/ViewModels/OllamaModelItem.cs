using AINotebook.Core.Ollama;

namespace AINotebook.App.ViewModels;

public sealed class OllamaModelItem
{
    public string Name { get; }
    public string SizeText { get; }

    public OllamaModelItem(OllamaModel model)
    {
        Name = model.Name;
        SizeText = FormatBinary(model.Size);
    }

    private static string FormatBinary(long bytes)
    {
        string[] units = { "bytes", "KiB", "MiB", "GiB", "TiB" };
        double size = bytes;
        int u = 0;
        while (size >= 1024 && u < units.Length - 1) { size /= 1024; u++; }
        return u == 0 ? $"{bytes} {units[0]}" : $"{size:0.##} {units[u]}";
    }
}
