package app.keytitan

import android.app.Activity
import android.app.assist.AssistStructure
import android.content.Intent
import android.os.Bundle
import android.os.Build
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.service.autofill.Dataset
import android.widget.RemoteViews

/** The user tapped Continue login; revalidate and spend that single continuation. */
class KeyTitanAutofillContinueActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        setResult(RESULT_CANCELED)
        val session = AutofillSessions.claim(intent.getStringExtra("token").orEmpty())
        try {
            if (savedInstanceState != null || session == null || !session.continuation ||
                !AutofillSessions.valid(this, session)) return
            @Suppress("DEPRECATION")
            val structure = intent.getParcelableExtra<AssistStructure>(AutofillManager.EXTRA_ASSIST_STRUCTURE) ?: return
            val parsed = AutofillRequestParser.parse(structure, session.parsed.focusedId) ?: return
            if (parsed.contextFingerprint != session.parsed.contextFingerprint) return
            val login = AutofillContinuation.consume(this, session) ?: return
            val view = RemoteViews(packageName, R.layout.keytitan_autofill_dataset).apply {
                setTextViewText(R.id.keytitan_autofill_label, "KeyTitan")
            }
            val dataset = Dataset.Builder(view)
            parsed.usernameId?.let { dataset.setValue(it, AutofillValue.forText(login.username)) }
            parsed.passwordId?.let { dataset.setValue(it, AutofillValue.forText(login.password)) }
            val reply = Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset.build())
            if (Build.VERSION.SDK_INT >= 31) reply.putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT_EPHEMERAL_DATASET, true)
            setResult(RESULT_OK, reply)
        } finally {
            session?.let { AutofillContinuation.remove(it.flow); AutofillSessions.remove(it.token) }
            finish()
        }
    }
}
