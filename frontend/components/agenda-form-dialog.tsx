"use client"

import { zodResolver } from "@hookform/resolvers/zod"
import { format } from "date-fns"
import { ClipboardPaste, LoaderCircle, Plus, Sparkles, X } from "lucide-react"
import { type ComponentProps, useEffect, useRef, useState } from "react"
import { type Path, useFieldArray, useForm } from "react-hook-form"
import { toast } from "sonner"
import { z } from "zod"

import { Alert, AlertDescription } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Separator } from "@/components/ui/separator"
import { Textarea } from "@/components/ui/textarea"
import { useSaveAgenda } from "@/hooks/use-meetings"
import { ApiError } from "@/lib/api"
import { formatTime, parseIsoDay } from "@/lib/datetime"
import {
  isParserConfigured,
  MAX_PASTE_CHARS,
  ParserError,
  type ParseResult,
  parseAgenda,
} from "@/lib/parser"
import type { Agenda, Meeting } from "@/lib/types"
import { cn } from "@/lib/utils"

const MAX_ROWS = 50

const itemSchema = z.object({
  topic: z.string().trim().min(1, "Topic is required").max(300, "Topic is too long"),
  owner: z.string().trim().max(200, "Owner is too long"),
  minutes: z
    .string()
    .trim()
    .refine((v) => v === "" || (/^\d+$/.test(v) && Number(v) >= 1 && Number(v) <= 480), {
      message: "Minutes must be 1–480",
    }),
})

const actionSchema = z.object({
  task: z.string().trim().min(1, "Task is required").max(500, "Task is too long"),
  owner: z.string().trim().max(200, "Owner is too long"),
  due: z.string().refine((v) => v === "" || /^\d{4}-\d{2}-\d{2}$/.test(v), {
    message: "Use YYYY-MM-DD",
  }),
})

const formSchema = z.object({
  items: z.array(itemSchema).min(1, "Add at least one topic").max(MAX_ROWS),
  action_items: z.array(actionSchema).max(MAX_ROWS),
})

type FormValues = z.infer<typeof formSchema>

const blankItem = { topic: "", owner: "", minutes: "" }
const blankAction = { task: "", owner: "", due: "" }

/** Inputs hold strings; the API's nulls become empty fields and back. */
function toFormValues(agenda?: Agenda | null): FormValues {
  return {
    items: agenda?.items.length
      ? agenda.items.map((item) => ({
          topic: item.topic,
          owner: item.owner ?? "",
          minutes: item.minutes?.toString() ?? "",
        }))
      : [blankItem],
    action_items:
      agenda?.action_items.map((action) => ({
        task: action.task,
        owner: action.owner ?? "",
        due: action.due ?? "",
      })) ?? [],
  }
}

function toAgenda(values: FormValues): Agenda {
  return {
    items: values.items.map((item) => ({
      topic: item.topic,
      owner: item.owner || null,
      minutes: item.minutes ? Number(item.minutes) : null,
    })),
    action_items: values.action_items.map((action) => ({
      task: action.task,
      owner: action.owner || null,
      due: action.due || null,
    })),
  }
}

/** "Mon 19 Oct, 10:00 · 45 min" from the parts of the text that are not the agenda. */
function describeWhen(result: ParseResult): string {
  const { starts_at: startsAt, duration_minutes: minutes } = result.agenda
  const parts: string[] = []
  if (startsAt && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(startsAt)) {
    parts.push(`${format(parseIsoDay(startsAt), "EEE d MMM")}, ${formatTime(startsAt)}`)
  }
  if (minutes) parts.push(`${minutes} min`)
  return parts.join(" · ")
}

/** A field the model filled shows this until the user changes it. */
function SuggestedMark() {
  return (
    <Sparkles
      className="text-primary pointer-events-none absolute top-1/2 right-2.5 size-3.5 -translate-y-1/2"
      aria-label="suggested"
      role="img"
    />
  )
}

function Field({
  suggested,
  className,
  ...props
}: ComponentProps<typeof Input> & { suggested: boolean }) {
  return (
    <div className={cn("relative", className)}>
      <Input
        {...props}
        data-suggested={suggested || undefined}
        className="data-suggested:border-primary/50 data-suggested:bg-primary/5 data-suggested:pr-8"
      />
      {suggested ? <SuggestedMark /> : null}
    </div>
  )
}

type ParseState =
  | { status: "idle" }
  | { status: "parsing"; startedAt: number }
  | { status: "error"; message: string }

/** Add or edit a meeting's agenda by hand, or from pasted text the parser turns into a draft. */
export function AgendaFormDialog({
  open,
  onOpenChange,
  meeting,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  meeting?: Meeting
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90svh] overflow-y-auto sm:max-w-2xl">
        {/* Mounted on every open, so each visit starts from the saved agenda. */}
        {meeting ? <AgendaForm meeting={meeting} onClose={() => onOpenChange(false)} /> : null}
      </DialogContent>
    </Dialog>
  )
}

function AgendaForm({ meeting, onClose }: { meeting: Meeting; onClose: () => void }) {
  const saveAgenda = useSaveAgenda()
  const [pasted, setPasted] = useState("")
  const [parseState, setParseState] = useState<ParseState>({ status: "idle" })
  const [parsed, setParsed] = useState<ParseResult | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const abortRef = useRef<AbortController | null>(null)

  const {
    register,
    control,
    handleSubmit,
    reset,
    setError,
    formState: { errors, dirtyFields, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(formSchema),
    defaultValues: toFormValues(meeting.agenda),
  })
  const items = useFieldArray({ control, name: "items" })
  const actions = useFieldArray({ control, name: "action_items" })

  // Closing the dialog cancels a parse in flight.
  useEffect(() => () => abortRef.current?.abort(), [])

  // Ticks while parsing, so a long wait never looks frozen.
  const parsing = parseState.status === "parsing"
  useEffect(() => {
    if (!parsing) return
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [parsing])
  const elapsed = parsing ? Math.max(0, Math.floor((now - parseState.startedAt) / 1000)) : 0
  const tooLong = pasted.length > MAX_PASTE_CHARS

  const onParse = async () => {
    const controller = new AbortController()
    abortRef.current = controller
    setParseState({ status: "parsing", startedAt: Date.now() })
    try {
      const result = await parseAgenda(pasted, controller.signal)
      setParsed(result)
      // The suggestion becomes the form's baseline: a field stays "suggested"
      // until it differs from what the model wrote.
      reset(toFormValues(result.agenda))
      setParseState({ status: "idle" })
    } catch (error) {
      if (controller.signal.aborted) {
        setParseState({ status: "idle" })
        return
      }
      setParseState({
        status: "error",
        message: (error instanceof ParserError ? error : new ParserError("unavailable")).message,
      })
    } finally {
      if (abortRef.current === controller) abortRef.current = null
    }
  }

  const onCancelParse = () => abortRef.current?.abort()

  // A field is suggested when the model filled it and the user has not changed it.
  const itemSuggested = (index: number, field: "topic" | "owner" | "minutes") => {
    if (!parsed || index >= parsed.agenda.items.length) return false
    const value = parsed.agenda.items[index]?.[field]
    return value !== null && value !== "" && !dirtyFields.items?.[index]?.[field]
  }
  const actionSuggested = (index: number, field: "task" | "owner" | "due") => {
    if (!parsed || index >= parsed.agenda.action_items.length) return false
    const value = parsed.agenda.action_items[index]?.[field]
    return value !== null && value !== "" && !dirtyFields.action_items?.[index]?.[field]
  }

  const onSubmit = handleSubmit(async (values) => {
    try {
      await saveAgenda.mutateAsync({
        id: meeting.id,
        payload: {
          ...toAgenda(values),
          // What the model suggested, kept next to what the user saved.
          ai_suggestion: parsed
            ? {
                suggestion: parsed.agenda,
                model: parsed.model,
                prompt_version: parsed.prompt_version,
              }
            : null,
        },
      })
      toast.success("Agenda saved")
      onClose()
    } catch (error) {
      if (error instanceof ApiError) {
        for (const detail of error.details) {
          if (/^(items|action_items)(\.|$)/.test(detail.field)) {
            setError(detail.field as Path<FormValues>, { message: detail.message })
          }
        }
        toast.error(error.message)
      } else {
        toast.error("Could not save the agenda.")
      }
    }
  })

  const hint = parsed ? [parsed.agenda.title, describeWhen(parsed)].filter(Boolean).join(" · ") : ""

  return (
    <>
      <DialogHeader>
        <DialogTitle>{meeting.agenda ? "Edit agenda" : "Add agenda"}</DialogTitle>
        <DialogDescription>
          <span className="font-medium">{meeting.name}</span>
          {isParserConfigured
            ? " — type the topics, or paste an email or notes and check the draft."
            : " — the topics to cover, and who does what afterwards."}
        </DialogDescription>
      </DialogHeader>

      {isParserConfigured ? (
        <section className="space-y-2" aria-labelledby="paste-label">
          <Label id="paste-label" htmlFor="pasted">
            Paste an agenda
          </Label>
          <Textarea
            id="pasted"
            rows={4}
            value={pasted}
            onChange={(event) => setPasted(event.target.value)}
            disabled={parsing}
            placeholder="Пн 10:00, синк по прайсингу, 45 хв. 1) нові тарифи Pro — Олена, 15 хв 2) …"
            aria-describedby="paste-help"
            aria-invalid={tooLong || undefined}
          />
          <div className="flex flex-wrap items-center justify-between gap-2">
            <p
              id="paste-help"
              className={cn(
                "text-xs tabular-nums",
                tooLong ? "text-destructive" : "text-muted-foreground",
              )}
            >
              {pasted.length.toLocaleString("en")} / {MAX_PASTE_CHARS.toLocaleString("en")} ·
              Parsing replaces the form below. Nothing is saved until you press Save.
            </p>
            {parsing ? (
              <Button type="button" variant="outline" size="sm" onClick={onCancelParse}>
                <X aria-hidden />
                Cancel
              </Button>
            ) : (
              <Button
                type="button"
                variant="secondary"
                size="sm"
                onClick={onParse}
                disabled={!pasted.trim() || tooLong}
              >
                <ClipboardPaste aria-hidden />
                Parse
              </Button>
            )}
          </div>

          <div aria-live="polite">
            {parsing ? (
              <p className="text-muted-foreground flex items-center gap-2 text-sm">
                <LoaderCircle className="size-4 animate-spin" aria-hidden />
                Reading your agenda… usually 2–8 seconds
                {elapsed > 0 ? <span className="tabular-nums">({elapsed} s)</span> : null}
              </p>
            ) : null}
            {parseState.status === "error" ? (
              <Alert variant="destructive">
                <AlertDescription>
                  {parseState.message} You can still type the agenda below.
                </AlertDescription>
              </Alert>
            ) : null}
            {parsed && !parsing ? (
              <p className="text-muted-foreground flex flex-wrap items-center gap-1.5 text-sm">
                <Badge variant="secondary">
                  <Sparkles aria-hidden />
                  suggested
                </Badge>
                fields come from the text. Check them before saving.
              </p>
            ) : null}
          </div>
          {hint ? (
            <p className="text-muted-foreground text-xs">
              The text also mentions: {hint}. The meeting itself is not changed.
            </p>
          ) : null}
          <Separator className="mt-4" />
        </section>
      ) : null}

      <form onSubmit={onSubmit} className="space-y-6" noValidate>
        <fieldset className="space-y-2" disabled={parsing}>
          <legend className="mb-2 text-sm font-medium">Topics</legend>
          {items.fields.map((field, index) => {
            const rowError = errors.items?.[index]
            const message =
              rowError?.topic?.message ?? rowError?.owner?.message ?? rowError?.minutes?.message
            return (
              <div key={field.id} className="space-y-1">
                <div className="flex flex-wrap items-start gap-2">
                  <Field
                    className="min-w-0 flex-[2_1_14rem]"
                    aria-label={`Topic ${index + 1}`}
                    placeholder="Topic"
                    aria-invalid={!!rowError?.topic}
                    suggested={itemSuggested(index, "topic")}
                    {...register(`items.${index}.topic`)}
                  />
                  <Field
                    className="min-w-0 flex-[1_1_8rem]"
                    aria-label={`Topic ${index + 1} owner`}
                    placeholder="Owner"
                    suggested={itemSuggested(index, "owner")}
                    {...register(`items.${index}.owner`)}
                  />
                  <Field
                    className="w-24"
                    aria-label={`Topic ${index + 1} minutes`}
                    placeholder="Min"
                    inputMode="numeric"
                    aria-invalid={!!rowError?.minutes}
                    suggested={itemSuggested(index, "minutes")}
                    {...register(`items.${index}.minutes`)}
                  />
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    aria-label={`Remove topic ${index + 1}`}
                    onClick={() => items.remove(index)}
                    disabled={items.fields.length === 1}
                  >
                    <X className="size-4" aria-hidden />
                  </Button>
                </div>
                {message ? <p className="text-destructive text-sm">{message}</p> : null}
              </div>
            )
          })}
          {(errors.items?.message ?? errors.items?.root?.message) ? (
            <p className="text-destructive text-sm">
              {errors.items?.message ?? errors.items?.root?.message}
            </p>
          ) : null}
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={() => items.append(blankItem)}
            disabled={items.fields.length >= MAX_ROWS}
          >
            <Plus className="size-4" aria-hidden />
            Add topic
          </Button>
        </fieldset>

        <fieldset className="space-y-2" disabled={parsing}>
          <legend className="mb-2 text-sm font-medium">Action items</legend>
          {actions.fields.length === 0 ? (
            <p className="text-muted-foreground text-sm">None yet.</p>
          ) : null}
          {actions.fields.map((field, index) => {
            const rowError = errors.action_items?.[index]
            const message =
              rowError?.task?.message ?? rowError?.owner?.message ?? rowError?.due?.message
            return (
              <div key={field.id} className="space-y-1">
                <div className="flex flex-wrap items-start gap-2">
                  <Field
                    className="min-w-0 flex-[2_1_14rem]"
                    aria-label={`Action item ${index + 1}`}
                    placeholder="Task"
                    aria-invalid={!!rowError?.task}
                    suggested={actionSuggested(index, "task")}
                    {...register(`action_items.${index}.task`)}
                  />
                  <Field
                    className="min-w-0 flex-[1_1_8rem]"
                    aria-label={`Action item ${index + 1} owner`}
                    placeholder="Owner"
                    suggested={actionSuggested(index, "owner")}
                    {...register(`action_items.${index}.owner`)}
                  />
                  <Field
                    className="w-40"
                    type="date"
                    aria-label={`Action item ${index + 1} due date`}
                    aria-invalid={!!rowError?.due}
                    suggested={actionSuggested(index, "due")}
                    {...register(`action_items.${index}.due`)}
                  />
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    aria-label={`Remove action item ${index + 1}`}
                    onClick={() => actions.remove(index)}
                  >
                    <X className="size-4" aria-hidden />
                  </Button>
                </div>
                {message ? <p className="text-destructive text-sm">{message}</p> : null}
              </div>
            )
          })}
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={() => actions.append(blankAction)}
            disabled={actions.fields.length >= MAX_ROWS}
          >
            <Plus className="size-4" aria-hidden />
            Add action item
          </Button>
        </fieldset>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" disabled={isSubmitting || parsing}>
            {isSubmitting ? "Saving…" : "Save agenda"}
          </Button>
        </DialogFooter>
      </form>
    </>
  )
}
