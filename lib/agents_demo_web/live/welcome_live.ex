defmodule AgentsDemoWeb.WelcomeLive do
  use AgentsDemoWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen w-screen bg-[var(--color-background)] overflow-hidden">
      <div class="flex flex-1 items-center justify-center p-8">
        <div class="max-w-2xl w-full text-center">
          <div class="mb-8 flex justify-center">
            <div class="w-20 h-20 rounded-full bg-[var(--color-primary)] flex items-center justify-center">
              <.icon name="hero-chat-bubble-left-right" class="w-12 h-12 text-white" />
            </div>
          </div>

          <h1 class="text-5xl font-bold text-[var(--color-text-primary)] mb-4">
            Welcome to Agents Demo
          </h1>

          <p class="text-xl text-[var(--color-text-secondary)] mb-8 leading-relaxed">
            Experience the power of AI agents with interactive conversations, task management,
            and file operations - all in one place.
          </p>

          <div class="bg-[var(--color-surface)] border border-[var(--color-border)] rounded-xl p-8 mb-8">
            <h2 class="text-2xl font-semibold text-[var(--color-text-primary)] mb-6">
              Get Started
            </h2>

            <div class="mt-4 flex flex-col sm:flex-row gap-4 justify-center">
              <.link
                href={~p"/users/log-in"}
                class="px-8 py-4 flex items-center bg-[var(--color-primary)] text-white font-semibold rounded-lg hover:opacity-90 transition-opacity no-underline text-lg shadow-lg"
              >
                <.icon name="hero-arrow-right-on-rectangle" class="w-5 h-5 inline-block mr-2" />
                Log In
              </.link>

              <.link
                href={~p"/users/register"}
                class="px-8 py-4 flex items-center bg-[var(--color-surface)] text-[var(--color-text-primary)] font-semibold rounded-lg border-2 border-[var(--color-border)] hover:border-[var(--color-primary)] transition-colors no-underline text-lg"
              >
                <.icon name="hero-user-plus" class="w-5 h-5 inline-block mr-2" />
                Register
              </.link>
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-3 gap-6 text-left">
            <div class="bg-[var(--color-surface)] border border-[var(--color-border)] rounded-lg p-6">
              <div class="w-12 h-12 rounded-lg bg-[var(--color-primary)]/10 flex items-center justify-center mb-4">
                <.icon name="hero-chat-bubble-left-right" class="w-6 h-6 text-[var(--color-primary)]" />
              </div>
              <h3 class="text-lg font-semibold text-[var(--color-text-primary)] mb-2">
                Interactive Chat
              </h3>
              <p class="text-sm text-[var(--color-text-secondary)]">
                Engage in natural conversations with AI agents that understand context and provide intelligent responses.
              </p>
            </div>

            <div class="bg-[var(--color-surface)] border border-[var(--color-border)] rounded-lg p-6">
              <div class="w-12 h-12 rounded-lg bg-[var(--color-primary)]/10 flex items-center justify-center mb-4">
                <.icon name="hero-clipboard-document-check" class="w-6 h-6 text-[var(--color-primary)]" />
              </div>
              <h3 class="text-lg font-semibold text-[var(--color-text-primary)] mb-2">
                Task Management
              </h3>
              <p class="text-sm text-[var(--color-text-secondary)]">
                Watch agents break down complex tasks and track progress in real-time with visual indicators.
              </p>
            </div>

            <div class="bg-[var(--color-surface)] border border-[var(--color-border)] rounded-lg p-6">
              <div class="w-12 h-12 rounded-lg bg-[var(--color-primary)]/10 flex items-center justify-center mb-4">
                <.icon name="hero-document-text" class="w-6 h-6 text-[var(--color-primary)]" />
              </div>
              <h3 class="text-lg font-semibold text-[var(--color-text-primary)] mb-2">
                File Operations
              </h3>
              <p class="text-sm text-[var(--color-text-secondary)]">
                View and manage files created by agents during conversations with an intuitive interface.
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
