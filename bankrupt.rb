#!/usr/bin/env ruby

# frozen_string_literal: true

require "net/http"
require "csv"
require "nokogiri"
require "json"
require "date"

Bankrupt = Struct.new(:id, :password, :company, :company_password) do
  def initialize(...)
    super(...)
    @accounts_url = "https://www.itaulink.com.uy/trx/" # default
  end

  Balance = Struct.new(:date, :amount, :description, :instalment, :instalments) do
    def instalments_suffix
      " #{instalment}/#{instalments}" if instalment || instalments
    end
  end

  CreditCard = Struct.new(:brand, :owner_id, :hash, :account, :id) do
    def filename
      ["credit_card", id, owner_id].join("-")
    end

    def url
      "https://www.itaulink.com.uy/trx/tarjetas/credito/#{hash}/movimientos_actuales"
    end

    def file_url_for_month(year = Time.now.year, month = Time.now.month)
      url + "/#{year}#{month}00"
    end

    def balance_from_itau(year, month)
      @_balance_cache ||= {}
      url = file_url_for_month(year, month)
      puts "Downloading from: #{url}" unless @_balance_cache[url]
      @_balance_cache[url] ||= Bankrupt.get(url).body
    end

    def balance(year, month, currency)
      balances = []

      json_string = balance_from_itau(year, month)
      txns = JSON.parse(json_string)["itaulink_msg"]["data"]["datos"]["datosMovimientos"]["movimientos"]
      txns.select! { _1["moneda"] == currency }

      txns.each do |line|
        fecha = line["fecha"]
        date = Date.new(fecha["year"], fecha["monthOfYear"], fecha["dayOfMonth"])
        amount = line["importe"] * -1
        description = line["nombreComercio"]
        instalment, instalments = nil
        instalment, instalments = line["nroCuota"], line["cantCuotas"] if line["tipo"] == "Plan Pagos"
        balances << Balance.new(date, amount, description, instalment, instalments) if transaction_data?(description) && date <= Date.today
      end

      balances
    end

    def transaction_data?(description)
      # Beware: during my analysis of the data it seems data with "Recibo de Pago" is the last month's positive balance
      # which must be ignored but there are other records with "RECIBO DE PAGO" which are actual payment transactions.
      [/^Recibo de Pago$/]
        .none? { |e| description.to_s.strip.match?(e) }
    end

    def balance_as_ynab_csv(year, month, currency)
      csv = %w[Date Payee Category Memo Outflow Inflow].to_csv

      balance(year, month, currency).each do |item|
        csv << [
          item.date,
          item.description,
          "",
          item.description + item.instalments_suffix.to_s,
          [0, item.amount].min * -1,
          [0, item.amount].max
        ].to_csv
      end

      csv
    end
  end

  Account = Struct.new(:type_name, :type, :hash, :currency, :number, :balance) do
    def filename
      "#{type_name}-#{number}-#{currency}"
    end

    def url
      "https://www.itaulink.com.uy/trx/cuentas/#{type}/#{hash}"
    end

    def file_url_for_last_days(format = "TXT")
      url + "/reporteEstadoCta/#{format}?diasAtras=5" # 5 is the only value that works :-/
    end

    def file_url_for_month(year = Time.now.year, month = Time.now.month, format = "TXT")
      url + "/reporteEstadoCta/#{format}?anio=#{year}&mes=#{month}"
    end

    def balance_from_itau(year, month)
      url = year && month ? file_url_for_month(year, month) : file_url_for_last_days

      puts "Downloading from: #{url}"
      response = Bankrupt.get(url)
      response.body
    end

    def balance_as_csv(year, month)
      csv = %w[Date Amount Description].to_csv

      balance(year, month).each do |item|
        csv << [item.date, item.amount, item.description].to_csv
      end

      csv
    end

    def balance_as_ynab_csv(year, month)
      csv = %w[Date Payee Category Memo Outflow Inflow].to_csv

      balance(year, month).each do |item|
        csv << [
          item.date,
          item.description,
          "",
          item.description,
          [0, item.amount].min * -1,
          [0, item.amount].max
        ].to_csv
      end

      csv
    end

    def balance(year, month)
      balances = []

      balance_from_itau(year, month).each_line do |line|
        data = line.chomp.unpack("a7a4a7a2a15a15a*")
        date = Date.parse(data[2])
        amount = data[5].to_f - data[4].to_f
        description = data[6].gsub(/\s\s*/, " ")
        balances << Balance.new(date, amount, description) if transaction_data?(description) && date <= Date.today
      end

      balances
    end

    def transaction_data?(description)
      [/^CONCEPTO/, /^SALDO INICIAL/, /^SALDO FINAL/]
        .none? { |e| description.to_s.strip.match?(e) }
    end
  end

  class << self
    attr_accessor :cookie, :ua

    def http
      @_http ||= begin
        uri = URI.parse("https://www.itaulink.com.uy/")
        http = Net::HTTP.new(uri.host, uri.port)
        http.set_debug_output $stdout if ENV["DEBUG"]
        http.use_ssl = true
        http
      end
    end

    def get(url, headers = {})
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri.request_uri, headers)
      request["Cookie"] = Bankrupt.cookie if Bankrupt.cookie
      request["User-Agent"] = @ua if @ua

      http.request(request)
    end

    def post(url, data = nil)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri.request_uri)
      request.set_form_data(data) if data
      request["Cookie"] = Bankrupt.cookie if Bankrupt.cookie
      request["User-Agent"] = Bankrupt.ua if Bankrupt.ua

      http.request(request)
    end
  end

  def login
    response =
      Bankrupt.post(
        "https://www.itaulink.com.uy/trx/doLogin", {
          id: "login",
          tipo_usuario: "R",
          tipo_documento: "1",
          nro_documento: id,
          pass: password,
          password: password
        }
      )

    cookie = response["Set-Cookie"].split("; ")[0]
    @accounts_url = response["Location"]
    puts "Account URL: #{@accounts_url}"

    Bankrupt.cookie = cookie
  end

  def company_login
    response =
      Bankrupt.post(
        "https://www.itaulink.com.uy/appl/servlet/FeaServlet", {
          id: "login",
          tipo_usuario: "C",
          empresa: company.upcase,
          empresa_aux: company,
          pwd_empresa: company_password,
          usuario: id,
          usuario_aux: id,
          pwd_usuario: password
        }
      )

    cookie = response["Set-Cookie"].split("; ")[0]
    @accounts_url = response["Location"]

    Bankrupt.cookie = cookie
  end

  def accounts
    @_accounts ||= begin
      response = Bankrupt.get(@accounts_url)
      json_string = response.body[/var mensajeUsuario = JSON.parse\('(.*)'\);/, 1]
      json = JSON.parse(json_string)
      accounts = []

      accounts_json = json["cuentas"]
      accounts_json.each_key do |account_type|
        accounts_json[account_type].each do |account_data|
          accounts << Account.new(
            account_type,
            account_data["tipoCuenta"],
            account_data["hash"],
            account_data["moneda"],
            account_data["idCuenta"],
            account_data["saldo"]
          )
        end
      end

      puts "There are #{accounts.size} accounts. (#{accounts.map(&:number).join(',')})"

      accounts
    end
  end

  def credit_cards
    @_credit_cards ||= begin
      json_string = Bankrupt.post("https://www.itaulink.com.uy/trx/tarjetas/credito").body
      json = JSON.parse(json_string)

      credit_cards = []
      credit_cards_json = json["itaulink_msg"]["data"]["objetosTarjetaCredito"]["tarjetaImagen"].map(&:first)
      credit_cards_json.each do |card_data|
        credit_cards << CreditCard.new(
          card_data["selloFormateado"],
          card_data["numeroDocumentoTitular"],
          card_data["hash"],
          card_data["nroCuenta"],
          card_data["id"]
        )
      end

      puts "There are #{credit_cards.size} credit_cards. (#{credit_cards.map(&:hash).join(',')})"

      credit_cards
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  account_id = ARGV.fetch(0, ENV["CI"])
  password = ARGV.fetch(1, ENV["PASSWORD"])
  year = ARGV.fetch(2, ENV["YEAR"])
  month = ARGV.fetch(3, ENV["MONTH"])
  ynab = ARGV.fetch(4, ENV["YNAB"])
  cookie = ARGV.fetch(5, ENV["COOKIE"])

  bankrupt = Bankrupt.new(account_id, password)
  if cookie
    # JSESSIONID=0000hgDqEKKCW9FbRzAwmbyRId5:1agva4a5p; Path=/; Secure; HttpOnly
    Bankrupt.cookie = cookie.split("; ")[0]
    Bankrupt.ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36"
  else
    bankrupt.login
  end

  puts
  puts "Fetching accounts information..."
  bankrupt.accounts.each do |account|
    filename = "#{[account.filename, year, month].compact.join('-')}.csv"
    csv =
      if ynab
        account.balance_as_ynab_csv(year, month)
      else
        account.balance_as_csv(year, month)
      end
    open(filename, "w") << csv

    puts "#{filename} exported"
  end

  puts
  puts "Fetching credit cards information..."
  bankrupt.credit_cards.uniq(&:account).each do |cc|
    ["Pesos", "Dolares"].each do |currency|
      filename = "#{[cc.filename, currency, year, month].compact.join('-')}.csv"
      csv =
        if ynab
          cc.balance_as_ynab_csv(year, month, currency)
        else
          cc.balance_as_csv(year, month)
        end
      open(filename, "w") << csv

      puts "#{filename} exported"
    end
  end
end
