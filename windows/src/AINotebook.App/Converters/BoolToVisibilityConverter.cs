using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace AINotebook.App.Converters;

/// Inverts a bool, then maps to <see cref="Visibility"/>:
/// <c>false</c> -> Visible, <c>true</c> -> Collapsed.
/// Used to show the messages scroller when the empty-state flag is false.
public sealed class InvertBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => (value is bool b && b) ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => value is Visibility v && v == Visibility.Collapsed;
}

/// Maps a string to <see cref="Visibility"/>: non-empty -> Visible, null/empty -> Collapsed.
/// Used to show the streaming bubble and error line only when text is present.
public sealed class StringToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => string.IsNullOrEmpty(value as string) ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}

/// Inverts a bool. Used to disable the input box while a send is in flight.
public sealed class InvertBoolConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => !(value is bool b && b);

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => !(value is bool b && b);
}

/// Maps a bool to <see cref="Visibility"/>: <c>true</c> -> Visible, <c>false</c> -> Collapsed.
public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => (value is bool b && b) ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => value is Visibility v && v == Visibility.Visible;
}

/// Maps an int count to <see cref="Visibility"/>: >0 -> Visible, 0 -> Collapsed.
public sealed class CountToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => (value is int n && n > 0) ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}
