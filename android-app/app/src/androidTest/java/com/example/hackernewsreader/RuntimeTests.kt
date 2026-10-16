package com.example.hackernewsreader

import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.Snapshot
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import hacker.news.reader.Message
import hacker.news.reader.Model
import hacker.news.reader.SendMessageAction
import hacker.news.reader.Strings
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
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
                val model = Model()
                val values = async(start = CoroutineStart.UNDISPATCHED) {
                    snapshotFlow { model.searchQuery }.take(2).toList()
                }
                model.searchQuery = "Swift é 😀 %@"
                assertEquals("Swift é 😀 %@", model.searchQuery)
                Snapshot.sendApplyNotifications()
                assertEquals(listOf("", "Swift é 😀 %@"), values.await())
                assertEquals("Searching for “Swift é 😀 %@”", Strings.searchHeader(model.searchQuery))
            }
        }
    }

    @Test fun liveActionReturnsThroughSwiftMainActor() = runBlocking {
        withTimeout(5000) {
            withContext(Dispatchers.Main) {
                val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as App
                val action = SendMessageAction(app.core)
                action.run(Message.toggleRead("missing-story"))
                assertEquals(0, app.core.model.feedStories.count)
                assertEquals("", app.core.model.searchQuery)
            }
        }
    }
}
