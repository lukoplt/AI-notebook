using System.Runtime.CompilerServices;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>UI redesign C1: the composer Stop button (cancel the running turn, keep the partial answer).</summary>
public sealed class ChatStopTests
{
    [Fact]
    public void TurnControlCancelsOnlyTheRunningTurn()
    {
        var turn = new ChatTurnControl();
        Assert.False(turn.Stop());
        var (first, g1) = turn.Begin();
        Assert.True(turn.IsRunning);
        Assert.True(turn.Stop());
        Assert.True(first.IsCancellationRequested);
        Assert.True(turn.StopRequested);
        turn.End(g1);
        Assert.False(turn.IsRunning);
        Assert.False(turn.StopRequested);

        var (second, g2) = turn.Begin();
        Assert.False(turn.IsCurrent(g1));   // late tokens of the stopped turn are dropped
        Assert.True(turn.IsCurrent(g2));
        Assert.False(second.IsCancellationRequested);
        turn.End(g1);                       // ending a stale turn leaves the running one alone
        Assert.True(turn.IsRunning);
        turn.End(g2);
    }

    [Fact]
    public async Task StoppedNewTurnKeepsItsPartialAnswerUnderTheQuestion()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long nb = store.CreateNotebook("N").Id!.Value;
        long sid = store.CreateChatSession(nb, "T").Id!.Value;
        var chat = new StallingChat("Partial ", "answer [1]\n");
        var engine = new ChatEngine(store, new Retriever(store, new ZeroEmbedder(), "m"), chat, "m", retryBackoffMillis: 0);
        var turn = new ChatTurnControl();
        var (ct, generation) = turn.Begin();

        var intent = await engine.CaptureIntentAsync(sid, nb, "What is it?", new RetrievalScope.All(), ct: ct);
        var handle = await engine.PrepareAsync(intent, ct);
        string draft = "";
        var streaming = engine.SendPreparedAsync(handle, handle.Key, t => draft += t, null, ct);
        await chat.Streamed.Task.WaitAsync(TimeSpan.FromSeconds(30));

        Assert.True(turn.Stop());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => streaming);
        Assert.True(turn.StopRequested && turn.IsCurrent(generation));

        // A replacement (regenerate/edit) or a turn stopped before sending writes nothing.
        Assert.Null(StoppedTurn.Persist(store, sid, handle, draft, isReplacement: true));
        Assert.Null(StoppedTurn.Persist(store, sid, null, draft, isReplacement: false));
        Assert.Null(StoppedTurn.Persist(store, sid, handle, " \n", isReplacement: false));

        var saved = StoppedTurn.Persist(store, sid, handle, draft, isReplacement: false);
        Assert.NotNull(saved);
        Assert.Empty(saved!.Citations); // [1] was not in the (empty) pack
        var history = store.Messages(sid);
        Assert.Equal(new[] { (ChatRole.User, "What is it?"), (ChatRole.Assistant, "Partial answer [1]") },
            history.Select(m => (m.Role, m.Content)));
        turn.End(generation);
        Assert.False(turn.IsRunning);
    }

    [Fact]
    public async Task StoppedNewTurnWithoutTokensWithdrawsItsQuestion()
    {
        // Stopped after streaming began but before any token: the saved question is removed and returns
        // to the composer, so sending it again stores it once (parity: ChatStopTests.swift).
        using var store = new NotebookStore(StorePath.InMemory);
        long nb = store.CreateNotebook("N").Id!.Value;
        long sid = store.CreateChatSession(nb, "T").Id!.Value;
        store.AppendContextUser(sid, "Earlier?");
        store.CommitContextAssistant(sid, "Earlier.", [], "m", null, null, null);
        long? newestIdBeforeSend = store.Messages(sid).Select(m => m.Id).Max();
        var chat = new StallingChat();
        var engine = new ChatEngine(store, new Retriever(store, new ZeroEmbedder(), "m"), chat, "m", retryBackoffMillis: 0);
        var turn = new ChatTurnControl();
        var (ct, generation) = turn.Begin();

        var intent = await engine.CaptureIntentAsync(sid, nb, "What is it?", new RetrievalScope.All(), ct: ct);
        var handle = await engine.PrepareAsync(intent, ct);
        string draft = "";
        var streaming = engine.SendPreparedAsync(handle, handle.Key, t => draft += t, null, ct);
        await chat.Streamed.Task.WaitAsync(TimeSpan.FromSeconds(30));
        Assert.Equal(3, store.Messages(sid).Count);

        Assert.True(turn.Stop());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => streaming);
        Assert.Equal("", draft);
        Assert.Null(StoppedTurn.Persist(store, sid, handle, draft, isReplacement: false));

        // A replacement, a kept partial answer, or a turn stopped before sending leaves the history alone.
        Assert.False(StoppedTurn.WithdrawQuestion(store, sid, handle, draft, true, "What is it?", newestIdBeforeSend));
        Assert.False(StoppedTurn.WithdrawQuestion(store, sid, handle, "Part", false, "What is it?", newestIdBeforeSend));
        Assert.False(StoppedTurn.WithdrawQuestion(store, sid, null, draft, false, "What is it?", newestIdBeforeSend));
        Assert.Equal(3, store.Messages(sid).Count);

        Assert.True(StoppedTurn.WithdrawQuestion(store, sid, handle, draft, false, "What is it?", newestIdBeforeSend));
        Assert.Equal(new[] { "Earlier?", "Earlier." }, store.Messages(sid).Select(m => m.Content));
        // Nothing left to remove: the question still returns to the composer, the history is untouched.
        Assert.True(StoppedTurn.WithdrawQuestion(store, sid, handle, draft, false, "What is it?", newestIdBeforeSend));
        Assert.Equal(2, store.Messages(sid).Count);
        turn.End(generation);

        // Sending again stores the question once.
        var again = new ChatEngine(store, new Retriever(store, new ZeroEmbedder(), "m"), new FinishingChat("Done."), "m",
            retryBackoffMillis: 0);
        var resend = await again.PrepareAsync(await again.CaptureIntentAsync(sid, nb, "What is it?", new RetrievalScope.All()));
        await again.SendPreparedAsync(resend, resend.Key, _ => { }, null);
        Assert.Equal(new[] { "Earlier?", "Earlier.", "What is it?", "Done." }, store.Messages(sid).Select(m => m.Content));
    }

    [Fact]
    public void ComposerSwapsSendForStopAndStoppedAnswersSaySo()
    {
        string root = ShellNavigationTests.AppRoot();
        string xaml = File.ReadAllText(Path.Combine(root, "Chat", "ChatThreadPage.xaml"));
        Assert.Contains("x:Name=\"StopButton\"", xaml);
        Assert.Contains("Command=\"{x:Bind ViewModel.StopCommand}\"", xaml);
        Assert.Contains("Glyph=\"{StaticResource IconStop}\"", xaml);
        string row = File.ReadAllText(Path.Combine(root, "Controls", "MessageRow.xaml"));
        Assert.Contains("x:Name=\"StoppedLabel\"", row);
        string vm = File.ReadAllText(Path.Combine(root, "ViewModels", "ChatViewModel.cs"));
        Assert.Contains("ct: ct);", vm); // the stream observes Stop
    }

    private sealed class ZeroEmbedder : IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default) =>
            Task.FromResult(inputs.Select(_ => new[] { 1f, 0f }).ToArray());
    }

    /// <summary>Streams one complete answer.</summary>
    private sealed class FinishingChat(string answer) : IChatStreaming
    {
        public async IAsyncEnumerable<string> StreamAsync(string model, IReadOnlyList<ChatTurn> messages,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            await Task.Yield();
            yield return answer;
        }
    }

    /// <summary>Streams its tokens, then waits until the caller cancels.</summary>
    private sealed class StallingChat(params string[] tokens) : IChatStreaming
    {
        public TaskCompletionSource Streamed { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async IAsyncEnumerable<string> StreamAsync(string model, IReadOnlyList<ChatTurn> messages,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            foreach (var token in tokens)
            {
                await Task.Yield();
                yield return token;
            }
            Streamed.TrySetResult();
            await Task.Delay(Timeout.Infinite, ct);
            yield break;
        }
    }
}
