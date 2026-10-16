package com.example.hackernewsreader.bridge

import android.os.Handler
import android.os.Looper
import com.example.hackernewsreader.swift.AndroidReader
import com.example.hackernewsreader.swift.Message as NativeMessage
import com.example.hackernewsreader.swift.Command as NativeCommand
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.swift.swiftkit.core.SwiftArena
import kotlin.coroutines.resume

sealed interface Message {
    data class ToggleRead(val id: String) : Message
    data class OpenStory(val id: String) : Message
    data object Refresh : Message
    data object LoadMore : Message

    companion object {
        fun toggleRead(id: String): Message = ToggleRead(id)
        fun openStory(id: String): Message = OpenStory(id)
        val refresh: Message = Refresh
        val loadMore: Message = LoadMore
    }
}

sealed interface Command {
    data class PresentURL(val value: String) : Command
}

/** Owns the native reader for the Application lifetime, not an Activity lifetime. */
class Core : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
    private val arena = SwiftArena.ofConfined()
    private val native = AndroidReader.init(arena)
    private var closed = false
    private var commandConsumer: ProducerScope<Command>? = null
    val model = Model(native)

    val commands = callbackFlow {
        checkMain()
        commandConsumer = this
        val token = native.observeCommands {
            SwiftArena.ofConfined().use { commandArena ->
                // Sending can resume a collector inline, and that collector can close Core.
                while (!closed) {
                    val command = native.takeCommand(commandArena).orElse(null) ?: break
                    when (val value = command.getCase()) {
                        is NativeCommand.Case.PresentURL -> trySend(Command.PresentURL(value.value()))
                    }
                }
            }
        }
        awaitClose { onMain { commandConsumer = null; native.cancel(token) } }
    }.buffer(Channel.UNLIMITED).flowOn(Dispatchers.Main.immediate)

    internal fun start(message: Message, completion: (Boolean) -> Unit): Long {
        checkMain()
        return SwiftArena.ofConfined().use { messageArena ->
            val value = when (message) {
                is Message.ToggleRead -> NativeMessage.toggleRead(message.id, messageArena)
                is Message.OpenStory -> NativeMessage.openStory(message.id, messageArena)
                Message.Refresh -> NativeMessage.refresh(messageArena)
                Message.LoadMore -> NativeMessage.loadMore(messageArena)
            }
            native.start(value) { completion(it) }
        }
    }

    internal fun cancel(token: Long) = onMain { native.cancel(token) }

    private fun onMain(body: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            if (!closed) body()
        } else {
            main.post { if (!closed) body() }
        }
    }

    private fun checkMain() {
        check(Looper.myLooper() == Looper.getMainLooper())
        check(!closed)
    }

    override fun close() {
        if (closed) return
        checkMain()
        closed = true
        commandConsumer?.close()
        commandConsumer = null
        model.close()
        native.close()
        arena.close()
    }
}

class SendMessageAction(private val core: Core) {
    fun send(message: Message) { core.start(message) {} }

    suspend fun run(message: Message) = withContext(Dispatchers.Main.immediate) {
        suspendCancellableCoroutine { continuation ->
            val token = core.start(message) { completed ->
                if (completed) continuation.resume(Unit) else continuation.cancel()
            }
            continuation.invokeOnCancellation { core.cancel(token) }
        }
    }
}
