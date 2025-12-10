defmodule AgentsDemoWeb.UserLive.Login do
  use AgentsDemoWeb, :live_view

  alias AgentsDemo.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen w-screen bg-[var(--color-background)] overflow-hidden">
      <div class="flex flex-1 items-center justify-center p-8">
        <div class="max-w-md w-full">
          <div class="mb-8 flex justify-center">
            <.link navigate={~p"/"} class="no-underline">
              <div class="w-16 h-16 rounded-full bg-[var(--color-primary)] flex items-center justify-center">
                <.icon name="hero-chat-bubble-left-right" class="w-10 h-10 text-white" />
              </div>
            </.link>
          </div>

          <div class="bg-[var(--color-surface)] border border-[var(--color-border)] rounded-xl p-8 shadow-lg">
            <div class="text-center mb-6">
              <h1 class="text-3xl font-bold text-[var(--color-text-primary)] mb-2">Log In</h1>
              <p class="text-[var(--color-text-secondary)]">
                <%= if @current_scope do %>
                  You need to reauthenticate to perform sensitive actions on your account.
                <% else %>
                  Don't have an account?
                  <.link
                    navigate={~p"/users/register"}
                    class="font-semibold text-[var(--color-primary)] hover:underline no-underline"
                  >
                    Sign up
                  </.link>
                  for an account now.
                <% end %>
              </p>
            </div>

            <div
              :if={local_mail_adapter?()}
              class="mb-6 p-4 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg"
            >
              <div class="flex gap-3">
                <.icon
                  name="hero-information-circle"
                  class="w-6 h-6 text-blue-600 dark:text-blue-400 flex-shrink-0"
                />
                <div class="text-sm text-blue-900 dark:text-blue-100">
                  <p class="font-semibold mb-1">Local mail adapter active</p>
                  <p>
                    To see sent emails, visit <.link href="/dev/mailbox" class="underline font-medium">the mailbox page</.link>.
                  </p>
                </div>
              </div>
            </div>

            <.form
              :let={f}
              for={@form}
              id="login_form_magic"
              action={~p"/users/log-in"}
              phx-submit="submit_magic"
              class="space-y-4"
            >
              <.input
                readonly={!!@current_scope}
                field={f[:email]}
                type="email"
                label="Email"
                autocomplete="username"
                required
                phx-mounted={JS.focus()}
              />
              <.button class="btn btn-primary w-full">
                Log in with email <span aria-hidden="true">→</span>
              </.button>
            </.form>

            <div class="relative my-6">
              <div class="absolute inset-0 flex items-center">
                <div class="w-full border-t border-[var(--color-border)]"></div>
              </div>
              <div class="relative flex justify-center text-sm">
                <span class="px-4 bg-[var(--color-surface)] text-[var(--color-text-secondary)]">
                  or
                </span>
              </div>
            </div>

            <.form
              :let={f}
              for={@form}
              id="login_form_password"
              action={~p"/users/log-in"}
              phx-submit="submit_password"
              phx-trigger-action={@trigger_submit}
              class="space-y-4"
            >
              <.input
                readonly={!!@current_scope}
                field={f[:email]}
                type="email"
                label="Email"
                autocomplete="username"
                required
              />
              <.input
                field={@form[:password]}
                type="password"
                label="Password"
                autocomplete="current-password"
              />
              <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
                Log in and stay logged in <span aria-hidden="true">→</span>
              </.button>
              <.button class="btn btn-primary btn-soft w-full mt-2">
                Log in only this time
              </.button>
            </.form>
          </div>

          <div class="mt-6 text-center">
            <.link
              navigate={~p"/"}
              class="text-sm text-[var(--color-text-secondary)] hover:text-[var(--color-primary)] no-underline"
            >
              ← Back to home
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:agents_demo, AgentsDemo.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
