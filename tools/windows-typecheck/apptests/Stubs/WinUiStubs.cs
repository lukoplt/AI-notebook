// Minimal stand-ins for the WinUI types the App view models touch, so App.Tests run on macOS
// (tools/windows-typecheck apptests only; never part of the App).
namespace Microsoft.UI.Dispatching
{
    public sealed class DispatcherQueue
    {
        public static DispatcherQueue GetForCurrentThread() => new();
        public bool HasThreadAccess => true;
        public bool TryEnqueue(System.Action a) { a(); return true; }
        public DispatcherQueueTimer CreateTimer() => new();
    }
    public sealed class DispatcherQueueTimer
    {
        public System.TimeSpan Interval { get; set; }
        public bool IsRepeating { get; set; }
        public event Windows.Foundation.TypedEventHandler<DispatcherQueueTimer, object>? Tick;
        public void Start() { }
        public void Stop() { }
        internal void Fire() => Tick?.Invoke(this, new object());
    }
}
namespace Windows.Foundation { public delegate void TypedEventHandler<TSender, TResult>(TSender sender, TResult args); }
namespace Microsoft.UI.Xaml
{
    public struct Thickness { public Thickness(double u) { Left = Top = Right = Bottom = u; } public Thickness(double l, double t, double r, double b) { Left = l; Top = t; Right = r; Bottom = b; } public double Left, Top, Right, Bottom; }
}
namespace Windows.System
{
    public static class Launcher { public static global::System.Threading.Tasks.Task<bool> LaunchUriAsync(global::System.Uri u) => global::System.Threading.Tasks.Task.FromResult(true); }
}
namespace AINotebook.App.Views { internal static class HarnessViewsNamespace { } }
