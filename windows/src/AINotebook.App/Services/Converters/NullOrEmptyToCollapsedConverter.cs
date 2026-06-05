using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace AINotebook.App.Services.Converters;

/// Returns <see cref="Visibility.Collapsed"/> for a null or empty/whitespace value,
/// otherwise <see cref="Visibility.Visible"/>. Used to hide the inline error line
/// in NewNotebookDialog until an error message is present.
public sealed class NullOrEmptyToCollapsedConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => string.IsNullOrWhiteSpace(value as string) ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}
