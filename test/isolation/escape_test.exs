defmodule Universe.Isolation.EscapeTest do
  @moduledoc """
  Containment checks for the configured isolation adapter. Every test is a
  snippet trying to get out; each must fail (or be cleaned up) without
  touching anything outside its lease.
  """

  use ExUnit.Case, async: false

  @moduletag :isolation

  alias Universe.{API, Paths}

  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp attempt(code, extra \\ %{}) do
    label = uniq("escape")
    d = Map.merge(%{"op" => "run", "label" => label, "lang" => "bash", "code" => code}, extra)
    result = API.tick(%{"directives" => [d], "wait" => %{"timeout_s" => 30}})
    [{"#" <> id, %{"status" => status}}] = Map.to_list(result.structured["ids"])
    {status, String.to_integer(id), result.text}
  end

  setup do
    root = Paths.project_root()
    lease = "lease-#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join(root, lease))
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, "src/victim.txt"), "original")
    %{root: root, lease: lease}
  end

  test "writing outside the lease fails", %{root: root, lease: lease} do
    {status, _, _} = attempt("echo pwned > src/victim.txt", %{"leases" => [lease]})
    assert status == "failed"
    assert File.read!(Path.join(root, "src/victim.txt")) == "original"
  end

  test "a symlink inside the lease doesn't lead out", %{root: root, lease: lease} do
    File.ln_s!(Path.join(root, "src"), Path.join([root, lease, "link"]))
    {status, _, _} = attempt("echo pwned > #{lease}/link/victim.txt", %{"leases" => [lease]})
    assert status == "failed"
    assert File.read!(Path.join(root, "src/victim.txt")) == "original"
  end

  test "creating a symlink in the lease and writing through it fails", %{root: root, lease: lease} do
    code = "ln -s ../src #{lease}/l2 && echo pwned > #{lease}/l2/victim.txt"
    {status, _, _} = attempt(code, %{"leases" => [lease]})
    assert status == "failed"
    assert File.read!(Path.join(root, "src/victim.txt")) == "original"
  end

  test ".. traversal out of the lease fails", %{root: root, lease: lease} do
    {status, _, _} = attempt("echo pwned > #{lease}/../src/victim.txt", %{"leases" => [lease]})
    assert status == "failed"
    assert File.read!(Path.join(root, "src/victim.txt")) == "original"
  end

  test "hard-linking an outside file into the lease fails", %{root: root, lease: lease} do
    code = "ln src/victim.txt #{lease}/hard && echo pwned > #{lease}/hard"
    {status, _, _} = attempt(code, %{"leases" => [lease]})
    assert status == "failed"
    assert File.read!(Path.join(root, "src/victim.txt")) == "original"
  end

  test "/tmp and $HOME are not writable" do
    marker = "universe-escape-#{System.unique_integer([:positive])}"
    {status, _, _} = attempt("echo x > /tmp/#{marker}")
    assert status == "failed"
    refute File.exists?("/tmp/#{marker}")

    {status, _, _} = attempt("echo x > #{System.user_home!()}/#{marker}")
    assert status == "failed"
    refute File.exists?(Path.join(System.user_home!(), marker))
  end

  test "the token, secrets, handles, logs and other workers' runs are unreadable", %{root: root} do
    File.write!(Paths.token_file(), "secret-token")
    File.mkdir_p!(Paths.secrets_dir())
    File.write!(Path.join(Paths.secrets_dir(), "x.env"), "K=v")
    File.mkdir_p!(Path.join(Paths.runs_dir(), "999998"))
    File.write!(Path.join([Paths.runs_dir(), "999998", "stdout"]), "other worker")

    for path <- [
          ".universe/token",
          ".universe/secrets/x.env",
          ".universe/log/events.jsonl",
          ".universe/runs/999998/stdout"
        ] do
      {status, _, _} = attempt("cat #{path}")
      assert status == "failed", "#{path} was readable"
    end

    assert File.exists?(Path.join(root, ".universe/token"))
  end

  test "$HOME is unreadable" do
    {status, _, _} = attempt("ls #{System.user_home!()}/.ssh #{System.user_home!()}/Documents")
    assert status == "failed"
  end

  test "a lease on the whole project still can't write .universe", %{root: root} do
    File.write!(Paths.token_file(), "keep-me")

    {status, _, _} =
      attempt("echo ok > src/allowed.txt && echo pwned > .universe/token", %{"leases" => ["."]})

    assert status == "failed"
    assert File.read!(Path.join(root, "src/allowed.txt")) == "ok\n"
    assert File.read!(Paths.token_file()) == "keep-me"
  end

  test "snippets have no network" do
    {status, _, _} = attempt("curl -s -m 3 http://1.1.1.1/ || exit 7")
    assert status == "failed"
  end

  test "a setsid daemon survives the worker (known gap, documented)" do
    # Containment does not yet kill processes that leave the group. The daemon
    # survives; the kernel is unaffected. Tracked in docs/PLAN.md.
    code = "(setsid sh -c 'sleep 300 & exit' &) ; sleep 0.3; echo forked"
    {status, _id, _text} = attempt(code)

    assert status == "done"
    System.cmd("pkill", ["-f", "sleep 300"])
  end
end
