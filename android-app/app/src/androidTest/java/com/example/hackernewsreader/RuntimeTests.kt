package com.example.hackernewsreader

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.Snapshot
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.hackernewsreader.bridge.Core
import com.example.hackernewsreader.bridge.Message
import com.example.hackernewsreader.bridge.SendMessageAction
import com.example.hackernewsreader.swift.Strings
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RuntimeTests {
    @Test fun generatedPropertyInvalidatesComposeAndPreservesUnicode() = runBlocking {
        withContext(Dispatchers.Main) {
            withTimeout(5000) {
                val core = Core()
                val model = core.model
                val handler = Handler(Looper.getMainLooper())
                val notifications = Snapshot.registerGlobalWriteObserver {
                    handler.post { Snapshot.sendApplyNotifications() }
                }
                try {
                    val values = async(start = CoroutineStart.UNDISPATCHED) {
                        snapshotFlow { model.searchQuery }.take(2).toList()
                    }
                    Snapshot.notifyObjectsInitialized()
                    model.searchQuery = "Swift é 😀 %@"
                    assertEquals("Swift é 😀 %@", model.searchQuery)
                    Snapshot.sendApplyNotifications()
                    assertEquals(listOf("", "Swift é 😀 %@"), values.await())
                    assertEquals("Searching for “Swift é 😀 %@”", Strings.searchHeader(model.searchQuery))
                } finally {
                    notifications.dispose()
                    core.close()
                }
            }
        }
    }

    @Test fun liveActionReturnsThroughSwiftMainActor() = runBlocking {
        withTimeout(5000) {
            withContext(Dispatchers.Main) {
                val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as App
                val action = SendMessageAction(app.core)
                action.run(Message.toggleRead("missing-story"))
                assertEquals(0, app.core.model.feedStories.size)
                assertEquals("", app.core.model.searchQuery)
            }
        }
    }

    @Test fun closingReaderCancelsWaiterAndCopiedValuesSurviveArenaClose() = runBlocking {
        withContext(Dispatchers.Main) {
            withTimeout(5000) {
                repeat(25) {
                    val core = Core()
                    val initial = core.model.feedInitialStatus
                    val pending = launch(start = CoroutineStart.UNDISPATCHED) {
                        SendMessageAction(core).run(Message.refresh)
                    }
                    core.close()
                    pending.join()
                    assertEquals(true, pending.isCancelled)
                    assertEquals(false, initial.isLoading)
                    assertEquals(null, initial.error)
                    System.gc()
                }
            }
        }
    }

    @Test fun cancellingCoroutineDoesNotCloseReader() = runBlocking {
        withContext(Dispatchers.Main) {
            withTimeout(5000) {
                val core = Core()
                try {
                    val action = SendMessageAction(core)
                    val pending = launch(start = CoroutineStart.UNDISPATCHED) {
                        action.run(Message.refresh)
                    }
                    pending.cancelAndJoin()
                    action.run(Message.toggleRead("after-cancellation"))
                    assertEquals("", core.model.searchQuery)
                } finally { core.close() }
            }
        }
    }
}
